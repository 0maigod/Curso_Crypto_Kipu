// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


/// @title KipuBankV2 — bóvedas personales de ETH y ERC-20 con control de acceso, pausas y rescates seguros.
/// @author Héctor Omar Ester
/// @notice Versión extendida de tu KipuBank:
///         - Mantiene bóvedas de ETH con umbral por retiro y tope global.
///         - Agrega bóvedas ERC-20 con umbral/cap por token.
///         - Controles de pausa por rol y rescates (ERC20/721/1155 y excedente nativo).
/// @dev Sigue patrón checks-effects-interactions, usa errores personalizados y evita reentrancy.

contract KipuBankV2 is AccessControl, Pausable {
    using SafeERC20 for IERC20;
    /*//////////////////////////////////////////////////////////////
                               ERRORES
    //////////////////////////////////////////////////////////////*/

    /// @notice Se revierte si el monto es cero.
    error ZeroAmount();

    /// @notice Se revierte si un retiro excede el umbral por transacción.
    /// @param requested Monto solicitado.
    /// @param threshold Umbral permitido.
    error ThresholdExceeded(uint256 requested, uint256 threshold);

    /// @notice Se revierte si el usuario no tiene balance suficiente.
    /// @param requested Monto solicitado.
    /// @param available Balance disponible del usuario.
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Se revierte si la operación supera el tope global de depósitos del banco.
    /// @param cap Límite global (bank cap).
    /// @param newTotal Total hipotético si se aceptara el depósito.
    error CapExceeded(uint256 cap, uint256 newTotal);

    /// @notice Se revierte si una transferencia nativa falla.
    error TransferFailed();

    /// @notice Se revierte si el destinatario es la dirección cero.
    error InvalidRecipient();

    /// @notice Se revierte si alguien envía ETH directo al contrato.
    error DirectDepositDisabled();

    /// @notice Se revierte si se detecta un intento de reentrancy.
    error ReentrancyDetected();

    /*//////////////////////////////////////////////////////////////
                               ROLES
    //////////////////////////////////////////////////////////////*/
    
    /// @dev Rol para pausar/despausar.
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    /// @dev Rol para operaciones de tesorería (rescates).
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    /*//////////////////////////////////////////////////////////////
                            VARIABLES DE ESTADO
    //////////////////////////////////////////////////////////////*/

    /// @notice Umbral máximo por retiro (fijo por transacción).
    /// @dev Inmutable, definido en el despliegue.
    uint256 public immutable withdrawThreshold;

    /// @notice Tope global del banco para la suma de todos los saldos.
    /// @dev Inmutable, definido en el despliegue.
    uint256 public immutable bankCap;

    /// @notice Suma de todos los saldos en todas las bóvedas.
    uint256 public totalReserves;

    /// @notice Cantidad de depósitos realizados (global).
    uint256 public depositCount;

    /// @notice Cantidad de retiros realizados (global).
    uint256 public withdrawalCount;

    /// @notice Saldo por usuario.
    mapping(address => uint256) private vault;

    /// @notice Cantidad de depósitos por usuario.
    mapping(address => uint64) public depositsBy;

    /// @notice Cantidad de retiros por usuario.
    mapping(address => uint64) public withdrawalsBy;

    /// @dev Flag simple para protección reentrancy.
    bool private _locked; // 0 = unlocked, 1 = locked

    /// @notice Configuración por token ERC-20 (umbral y cap independientes).
    /// @dev Permite políticas por token con economías distintas.
    struct TokenConfig {
        uint256 threshold; // umbral por retiro (por transacción) para el token
        uint256 cap;       // tope global (suma de saldos) para el token
        bool enabled;      // habilitado para operar (deposit/withdraw)
    }

    /// @notice Config por token: token => config.
    mapping(address => TokenConfig) public tokenConfig;

    /// @notice Total de reservas por token: token => total.
    mapping(address => uint256) public totalReservesToken;

    /// @notice Saldos por usuario y token: token => user => balance.
    mapping(address => mapping(address => uint256)) private vaultToken;

    /*//////////////////////////////////////////////////////////////
                                 EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Empleado cuando un usuario deposita exitosamente.
    /// @param user Dirección del depositante.
    /// @param amount Monto depositado en wei.
    event Deposit(address indexed user, uint256 amount);

    /// @notice Empleado cuando un usuario retira exitosamente.
    /// @param user Dueño de la bóveda.
    /// @param to Destinatario del retiro.
    /// @param amount Monto retirado en wei.
    event Withdrawal(address indexed user, address indexed to, uint256 amount);

    /// Excedente nativo (ETH forzado) rescatado
    event SurplusRescued(address indexed to, uint256 amount);

    /// Tokens ERC20 rescatados
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // Eventos de NFT/multi-token
    event ERC721Rescued(address indexed token, uint256 indexed tokenId, address indexed to);
    event ERC1155Rescued(address indexed token, uint256 indexed id, uint256 amount, address indexed to);

    // Eventos multi-token (operativa de usuarios)
    event TokenEnabled(address indexed token, uint256 threshold, uint256 cap);
    event TokenParamsUpdated(address indexed token, uint256 threshold, uint256 cap);
    event TokenDeposit(address indexed token, address indexed user, uint256 amount, uint256 received);
    event TokenWithdrawal(address indexed token, address indexed user, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _withdrawThreshold Umbral por retiro (wei).
    /// @param _bankCap Tope global de depósitos (wei).
    constructor(uint256 _withdrawThreshold, uint256 _bankCap) {
        if (_withdrawThreshold == 0 || _bankCap == 0) revert ZeroAmount();
        withdrawThreshold = _withdrawThreshold;
        bankCap = _bankCap;
        _locked = false;

        // Roles: el deployer es admin, pauser y tesorero inicial
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(TREASURER_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFICADORES
    //////////////////////////////////////////////////////////////*/

    /// @dev Evita reentrancy simple para funciones que mueven ETH.
    modifier nonReentrant() {
        if (_locked) revert ReentrancyDetected(); // reutilizamos error genérico
        _locked = true;
        _;
        _locked = false;
    }

    /*//////////////////////////////////////////////////////////////
                              FUNCIONES CORE (ETH)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposita ETH en bóveda personal.
    /// @dev Sigue checks-effects-interactions. Emite `Deposit`.
    /// @custom:security Usa nonReentrant para coherencia, aunque no transfiere ETH saliente.
    function deposit() 
        external 
        payable 
        nonReentrant 
        whenNotPaused
    {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        // CHECKS
        uint256 newTotal = totalReserves + amount;
        if (newTotal > bankCap) revert CapExceeded(bankCap, newTotal);

        // EFFECTS
        vault[msg.sender] += amount;
        totalReserves = newTotal;
        depositCount += 1;
        depositsBy[msg.sender] += 1;
        
        // INTERACTIONS: no hay
        emit Deposit(msg.sender, amount);
    }

    /// @notice Retira hasta `withdrawThreshold` (o menos) hacia `to`.
    /// @param amount Monto a retirar (wei).
    /// @param to Destinatario del retiro (no puede ser address(0)).
    /// @dev Sigue checks-effects-interactions, emite `Withdrawal`.
    function withdraw(uint256 amount, address payable to) 
        external 
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidRecipient();
        if (amount > withdrawThreshold) revert ThresholdExceeded(amount, withdrawThreshold);

        uint256 balance = vault[msg.sender];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        // EFFECTS
        vault[msg.sender] = balance - amount;
        totalReserves -= amount;
        withdrawalCount += 1;
        withdrawalsBy[msg.sender] += 1;
        
        // INTERACTIONS
        _safeTransferNative(to, amount);

        emit Withdrawal(msg.sender, to, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         FUNCIONES CORE (ERC-20)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Habilita/actualiza parámetros de un ERC-20 (umbral/cap) y su estado.
    /// @dev Solo en pausa por seguridad de operación. Requiere admin.
    /// @param token Dirección del token ERC-20.
    /// @param threshold Umbral por retiro por transacción (en unidades del token).
    /// @param cap Tope global (suma de saldos) para ese token.
    /// @param enabled Si el token queda habilitado para operar.
    function setTokenParams(address token, uint256 threshold, uint256 cap, bool enabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
    {
        if (token == address(0)) revert InvalidRecipient();
        if (threshold == 0 || cap == 0) revert ZeroAmount();

        TokenConfig storage cfg = tokenConfig[token];
        cfg.threshold = threshold;
        cfg.cap = cap;
        cfg.enabled = enabled;

        if (enabled) emit TokenEnabled(token, threshold, cap);
        emit TokenParamsUpdated(token, threshold, cap);
    }

    /// @notice Deposita un token ERC-20 habilitado en bóveda personal.
    /// @dev Soporta tokens fee-on-transfer midiendo `received`.
    /// @param token Interfaz del token.
    /// @param amount Monto a transferir desde el usuario al contrato.
    function depositToken(IERC20 token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        address t = address(token);
        TokenConfig memory cfg = tokenConfig[t];
        require(cfg.enabled, "token disabled");
        if (amount == 0) revert ZeroAmount();

        // INTERACTIONS (entrada) — medimos recibido real por fee-on-transfer
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = token.balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        require(received > 0, "no tokens received");

        // CHECKS
        uint256 newTotal = totalReservesToken[t] + received;
        if (newTotal > cfg.cap) revert CapExceeded(cfg.cap, newTotal);

        // EFFECTS
        vaultToken[t][msg.sender] += received;
        totalReservesToken[t] = newTotal;

        emit TokenDeposit(t, msg.sender, amount, received);
    }

    /// @notice Retira un token ERC-20 habilitado hacia `to` respetando el umbral por transacción.
    /// @param token Interfaz del token.
    /// @param amount Monto a retirar.
    /// @param to Destinatario (no puede ser address(0)).
    function withdrawToken(IERC20 token, uint256 amount, address to)
        external
        nonReentrant
        whenNotPaused
    {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();

        address t = address(token);
        TokenConfig memory cfg = tokenConfig[t];
        require(cfg.enabled, "token disabled");
        if (amount > cfg.threshold) revert ThresholdExceeded(amount, cfg.threshold);

        uint256 bal = vaultToken[t][msg.sender];
        if (amount > bal) revert InsufficientBalance(amount, bal);

        // EFFECTS
        vaultToken[t][msg.sender] = bal - amount;
        totalReservesToken[t] -= amount;

        // INTERACTIONS
        token.safeTransfer(to, amount);

        emit TokenWithdrawal(t, msg.sender, to, amount);
    }


    /*//////////////////////////////////////////////////////////////
                          FUNCIONES DE LECTURA
    //////////////////////////////////////////////////////////////*/

    /// @notice Obtiene el balance de la bóveda de un usuario.
    /// @param user Dirección del usuario.
    /// @return balance Balance en wei.
    function balanceOf(address user) external view returns (uint256 balance) {
        balance = vault[user];
    }

    /// @notice Devuelve métricas agregadas útiles para UIs.
    /// @return reserves Total en bóvedas, `totalReserves`.
    /// @return deposits Número de depósitos globales.
    /// @return withdrawals Número de retiros globales.
    /// @return cap Tope global.
    /// @return threshold Umbral por retiro.
    function stats()
        external
        view
        returns (uint256 reserves, uint256 deposits, uint256 withdrawals, uint256 cap, uint256 threshold)
    {
        return (totalReserves, depositCount, withdrawalCount, bankCap, withdrawThreshold);
    }

    // Balance por token ERC-20
    /// @notice Devuelve el balance de un usuario para un token ERC-20.
    function balanceOfToken(address token, address user) 
        external 
        view 
        returns (uint256) {
        return vaultToken[token][user];
    }

    // Métrica por token ERC-20
    /// @notice Devuelve métricas del token para UIs.
    /// @return reserves Total depositado del token.
    /// @return cap Tope global del token.
    /// @return threshold Umbral por retiro del token.
    /// @return enabled Si está habilitado para operar.
    function tokenStats(address token)
        external
        view
        returns (uint256 reserves, uint256 cap, uint256 threshold, bool enabled)
    {
        TokenConfig memory cfg = tokenConfig[token];
        return (totalReservesToken[token], cfg.cap, cfg.threshold, cfg.enabled);
    }

    // Vista de excedente nativo
    /// @notice Calcula el excedente nativo disponible para rescate (ETH forzado).
    function surplusNative() 
        public 
        view 
        returns (uint256) {
        uint256 bal = address(this).balance;
        return bal > totalReserves ? (bal - totalReserves) : 0;
    }

    /*//////////////////////////////////////////////////////////////
                    CONTROLES ADMIN (ROLES/PAUSAS)
    //////////////////////////////////////////////////////////////*/
    /// @notice Pausa depósitos y retiros (no afecta lecturas).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Reactiva depósitos y retiros.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////////////////
                       RESCATE / SEGURIDAD (solo en pausa)
    //////////////////////////////////////////////////////////////////////////*/
    /// @notice Rescata tokens ERC20 enviados por error al contrato.
    /// @dev No afecta ETH de usuarios; solo mueve tokens ajenos a la lógica del banco.
    function rescueERC20(address token, address to, uint256 amount)
        external
        onlyRole(TREASURER_ROLE)
        whenPaused
    {
        if (to == address(0)) revert InvalidRecipient();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Rescata un NFT ERC721 que fue enviado por error al contrato.
    /// @dev El contrato debe ser dueño actual de `tokenId`.
    function rescueERC721(IERC721 token, uint256 tokenId, address to)
        external
        onlyRole(TREASURER_ROLE)
        whenPaused
    {
        if (to == address(0)) revert InvalidRecipient();
        // Transferencia "segura": si `to` es contrato, debe implementar IERC721Receiver
        token.safeTransferFrom(address(this), to, tokenId);
        emit ERC721Rescued(address(token), tokenId, to);
    }

    /// @notice Rescata tokens ERC1155 enviados por error al contrato.
    /// @dev El contrato debe tener al menos `amount` del id `id`.
    function rescueERC1155(IERC1155 token, uint256 id, uint256 amount, address to, bytes calldata data)
        external
        onlyRole(TREASURER_ROLE)
        whenPaused
    {
        if (to == address(0)) revert InvalidRecipient();
        // Transferencia segura: si `to` es contrato, debe implementar IERC1155Receiver
        token.safeTransferFrom(address(this), to, id, amount, data);
        emit ERC1155Rescued(address(token), id, amount, to);
    }


    /// @notice Rescata ETH forzado (excedente sobre reservas de usuarios).
    /// @dev Mantiene el invariante: nunca se extrae ETH que respalda `totalReserves`.
    function rescueSurplusNative(address payable to) 
        external 
        onlyRole(TREASURER_ROLE)
        whenPaused
    {
        if (to == address(0)) revert InvalidRecipient();
        uint256 bal = address(this).balance;
        if (bal <= totalReserves) return; // no hay excedente
        uint256 surplus = bal - totalReserves;
        _safeTransferNative(to, surplus);
        emit SurplusRescued(to, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                    BLOQUEO DE ENVÍOS DIRECTOS / fallback
    //////////////////////////////////////////////////////////////*/

    /// @dev Bloquea envíos directos de ETH. Obliga a usar `deposit()`.
    receive() external payable {
        revert DirectDepositDisabled();
    }

    /// @dev Bloquea llamadas desconocidas.
    fallback() external payable {
        revert DirectDepositDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                          FUNCIONES INTERNAS / PRIVADAS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transferencia nativa segura usando `call`.
    /// @param to Destinatario.
    /// @param amount Monto en wei.
    /// @dev `private` para cumplir con el requisito y encapsular la interacción.
    function _safeTransferNative(address payable to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
