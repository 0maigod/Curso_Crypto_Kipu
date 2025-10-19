// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";


/*//////////////////////////////////////////////////////////////////////////
                              IMPORTS CHAINLINK
////////////////////////////////////////////////////////////////////////////*/

// Interfaz estándar de feeds Chainlink
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,       // precio
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title KipuBankV2 — bóvedas personales multi-token (ETH + ERC-20) con control de acceso, pausas y bank cap USD vía Chainlink.
/// @author Héctor Omar Ester
/// @notice Versión extendida de KipuBank:
///         - Contabilidad unificada por token (ETH = address(0)).
///         - Umbral de retiro por activo + cap por token.
///         - Bank cap global para ETH expresado en USD (8 dec) usando Chainlink.
///         - Eventos/errores detallados para mejor observabilidad.
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

    /// @notice Se revierte si el token especificado no está habilitado para operar.
    /// @param token Dirección del token deshabilitado.
    error TokenDisabled(address token);

    /// @notice Se revierte si la dirección del feed de precios de Chainlink es inválida.
    /// @param feed Dirección del feed que se intentó usar o configurar.
    error InvalidFeed(address feed);

    /// @notice Se revierte si el precio obtenido del oráculo es demasiado antiguo.
    /// @param feed Dirección del feed de Chainlink consultado.
    /// @param updatedAt Timestamp de la última actualización del precio.
    /// @param maxDelay Tiempo máximo permitido (en segundos) desde la última actualización.
    error StalePrice(address feed, uint256 updatedAt, uint256 maxDelay);

    /// @notice Se revierte si el oráculo devuelve un precio no válido (<= 0).
    /// @param feed Dirección del feed de Chainlink que devolvió un valor inválido.
    error InvalidPrice(address feed);

    /// @notice Se revierte si un depósito de ETH supera el tope global expresado en USD.
    /// @param capUsd Límite máximo del banco en USD (8 decimales).
    /// @param newUsdTotal Total en USD hipotético si se aceptara el depósito.
    error CapUsdExceeded(uint256 capUsd, uint256 newUsdTotal);

    /*//////////////////////////////////////////////////////////////
                               ROLES
    //////////////////////////////////////////////////////////////*/
    
    /// @dev Rol para pausar/despausar.
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    /// @dev Rol para operaciones de tesorería (rescates).
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                       CONSTANTES Y CONVENCIONES DE TOKENS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Convenio: address(0) representa ETH nativo.
    address public constant NATIVE = address(0);

    /*//////////////////////////////////////////////////////////////////////////
                         VARIABLES DE ESTADO — CONFIG GENERAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Guard simple anti-reentrancy (global).
    bool private _locked;

    /// @notice Umbral por retiro de ETH (fijo por transacción, en wei).
    /// @dev Inmutable como en tu diseño original.
    uint256 public immutable withdrawThresholdNative;

    /// @notice Bank cap global en **USD (8 decimales)** para las reservas de ETH.
    /// @dev Se compara contra el valor en USD calculado con Chainlink en cada depósito de ETH.
    uint256 public bankCapUsdNative; // Mutable, actualizable en pausa por admin

    /// Decimales "canónicos" para reportes (USDC-like = 6)
    uint8 public constant CANON_DECIMALS = 6;

    /// @notice Feed de Chainlink ETH/USD.
    AggregatorV3Interface public ethUsdFeed;

    /// @notice Umbral de frescura (segundos) para considerar válido un precio.
    uint256 public immutable priceStaleThreshold; // p.ej., 2 horas

    /*//////////////////////////////////////////////////////////////////////////
                 ESTADO — CONTABILIDAD UNIFICADA (ETH + ERC-20)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Configuración por token ERC-20 (y extensible a feeds por token).
    struct TokenConfig {
        uint256 threshold;  // umbral por retiro por transacción (en unidades del token)
        uint256 cap;        // tope global (suma de saldos) en unidades del token
        bool enabled;       // si está habilitado para operar
        uint8 decimals;     // cache de decimales del token (para vistas futuras)
        address priceFeed;  // (reservado para extensiones multi-feed)
    }

    /// @notice Config por token (excluye ETH, que usa sus propios parámetros).
    mapping(address => TokenConfig) public tokenConfig;

    /// @notice Suma de saldos por token (ETH usa `totalReservesNative`).
    mapping(address => uint256) public totalReservesToken;

    /// @notice Saldos por usuario por token. Para ETH: `balances[NATIVE][user]`.
    mapping(address => mapping(address => uint256)) private balances;

    /// @notice Reservas totales de ETH (wei).
    uint256 public totalReservesNative;

    /// @notice Métricas ETH (opcionales).
    uint256 public depositCountNative;
    uint256 public withdrawalCountNative;

    /*//////////////////////////////////////////////////////////////
                                 EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Empleado cuando un usuario deposita exitosamente.
    /// @param user Dirección del depositante.
    /// @param amount Monto depositado en wei.
    event DepositNative(address indexed user, uint256 amount);

    /// @notice Empleado cuando un usuario retira exitosamente.
    /// @param user Dueño de la bóveda.
    /// @param to Destinatario del retiro.
    /// @param amount Monto retirado en wei.
    event WithdrawalNative(address indexed user, address indexed to, uint256 amount);

    /// @notice Empleado cuando se habilita o configura por primera vez un token ERC-20.
    /// @param token Dirección del token ERC-20 habilitado.
    /// @param threshold Umbral máximo por retiro (en unidades del token).
    /// @param cap Tope global del banco para la suma de saldos de ese token.
    event TokenEnabled(address indexed token, uint256 threshold, uint256 cap);

    /// @notice Empleado cuando se actualizan los parámetros de un token ya registrado.
    /// @param token Dirección del token configurado.
    /// @param threshold Nuevo umbral máximo por retiro (en unidades del token).
    /// @param cap Nuevo tope global del banco para ese token.
    event TokenParamsUpdated(address indexed token, uint256 threshold, uint256 cap);

    /// @notice Empleado cuando un usuario deposita exitosamente un token ERC-20.
    /// @param token Dirección del token depositado.
    /// @param user Dirección del depositante.
    /// @param amount Monto solicitado a transferir (puede diferir del recibido si el token cobra comisión).
    /// @param received Monto efectivamente recibido por el contrato (tras posibles comisiones de transferencia).
    event TokenDeposit(address indexed token, address indexed user, uint256 amount, uint256 received);

    /// @notice Empleado cuando un usuario retira exitosamente un token ERC-20.
    /// @param token Dirección del token retirado.
    /// @param user Dueño de la bóveda.
    /// @param to Destinatario del retiro.
    /// @param amount Monto retirado (en unidades del token).
    event TokenWithdrawal(address indexed token, address indexed user, address indexed to, uint256 amount);

    /// Rescates
    /// Excedente nativo (ETH forzado) rescatado
    event SurplusRescued(address indexed to, uint256 amount);

    /// Tokens ERC20 rescatados
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // Rescates de NFT/Multi-token
    event ERC721Rescued(address indexed token, uint256 indexed tokenId, address indexed to);
    event ERC1155Rescued(address indexed token, uint256 indexed id, uint256 amount, address indexed to);

    /// @notice Empleado cuando se actualiza el feed de Chainlink para ETH/USD.
    /// @param feed Dirección del feed ETH/USD configurado.
    event EthUsdFeedUpdated(address indexed feed);

    /// @notice Empleado cuando se actualiza el tope global del banco expresado en USD.
    /// @param oldCapUsd Valor anterior del tope (8 decimales).
    /// @param newCapUsd Nuevo valor del tope (8 decimales).
    event BankCapUsdUpdated(uint256 oldCapUsd, uint256 newCapUsd);

    /*//////////////////////////////////////////////////////////////////////////
                                   CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _withdrawThresholdNative Umbral por retiro de ETH (wei).
    /// @param _bankCapUsdNative Cap global para ETH expresado en USD (8 decimales).
    /// @param _ethUsdFeed Dirección del Data Feed ETH/USD de Chainlink.
    /// @param _priceStaleThreshold Max delay aceptable (segundos) para considerar fresco el precio.
    constructor(
        uint256 _withdrawThresholdNative,
        uint256 _bankCapUsdNative,
        address _ethUsdFeed,
        uint256 _priceStaleThreshold
    ) {
        if (_withdrawThresholdNative == 0) revert ZeroAmount();
        if (_bankCapUsdNative == 0) revert ZeroAmount();
        if (_ethUsdFeed == address(0)) revert InvalidFeed(_ethUsdFeed);
        if (_priceStaleThreshold == 0) revert ZeroAmount();

        withdrawThresholdNative = _withdrawThresholdNative;
        bankCapUsdNative = _bankCapUsdNative;
        ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
        priceStaleThreshold = _priceStaleThreshold;

        _locked = false;

        // Roles iniciales
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(TREASURER_ROLE, msg.sender);

        emit EthUsdFeedUpdated(_ethUsdFeed);
        emit BankCapUsdUpdated(0, _bankCapUsdNative);
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

    /// @notice Deposita ETH (token = address(0)) en tu bóveda personal.
    /// @dev Verifica bank cap en USD usando Chainlink. Emite `DepositNative`.
    function depositNative() 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        // CHECK: bank cap USD (ETH solamente)
        uint256 newTotalWei = totalReservesNative + amount;
        uint256 newTotalUsd = _weiToUsd(newTotalWei); // Convierte usando Chainlink (8 dec)
        if (newTotalUsd > bankCapUsdNative) revert CapUsdExceeded(bankCapUsdNative, newTotalUsd);

        // EFFECTS
        balances[NATIVE][msg.sender] += amount;
        totalReservesNative = newTotalWei;
        depositCountNative += 1;

        // INTERACTIONS: no hay
        emit DepositNative(msg.sender, amount);
    }

    /// @notice Retira ETH hacia `to` respetando `withdrawThresholdNative`.
    function withdrawNative(uint256 amount, address payable to)
        external
        nonReentrant
        whenNotPaused
    {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        if (amount > withdrawThresholdNative) revert ThresholdExceeded(amount, withdrawThresholdNative);

        uint256 bal = balances[NATIVE][msg.sender];
        if (amount > bal) revert InsufficientBalance(amount, bal);

        // EFFECTS
        balances[NATIVE][msg.sender] = bal - amount;
        totalReservesNative -= amount;
        withdrawalCountNative += 1;

        // INTERACTIONS
        _safeTransferNative(to, amount);

        emit WithdrawalNative(msg.sender, to, amount);
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

        // cache de decimales (si el token no cumple metadata, asumimos 18)
        uint8 decs = 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            decs = d;
        } catch {}
        cfg.decimals = decs;

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
        if (amount == 0) revert ZeroAmount();
        address t = address(token);
        TokenConfig memory cfg = tokenConfig[t];
        if (!cfg.enabled) revert TokenDisabled(t);

        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = token.balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        require(received > 0, "no tokens received");

        uint256 newTotal = totalReservesToken[t] + received;
        if (newTotal > cfg.cap) revert CapExceeded(cfg.cap, newTotal);

        balances[t][msg.sender] += received;
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
        address t = address(token);
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();

        TokenConfig memory cfg = tokenConfig[t];
        if (!cfg.enabled) revert TokenDisabled(t);
        if (amount > cfg.threshold) revert ThresholdExceeded(amount, cfg.threshold);

        uint256 bal = balances[t][msg.sender];
        if (amount > bal) revert InsufficientBalance(amount, bal);

        balances[t][msg.sender] = bal - amount;
        totalReservesToken[t] -= amount;

        token.safeTransfer(to, amount);

        emit TokenWithdrawal(t, msg.sender, to, amount);
    }

    /// Escalado genérico entre decimales (sin redondeo "bankers", truncado)
    function _scaleDecimals(
        uint256 amount,
        uint8 fromDec,
        uint8 toDec
    ) internal pure returns (uint256) {
        if (fromDec == toDec) return amount;
        if (fromDec > toDec) {
            // reduce precisión
            return amount / (10 ** (fromDec - toDec));
        } else {
            // aumenta precisión (cuidado con overflow en casos extremos)
            return amount * (10 ** (toDec - fromDec));
        }
    }

    /// Normaliza monto ERC-20 a 6 dec (USDC-like)
    function _toCanonicalToken(address token, uint256 amount) 
        internal 
        view 
        returns (uint256) {
        // ETH usa address(0): 18 dec
        if (token == NATIVE) {
            return _scaleDecimals(amount, 18, CANON_DECIMALS);
        }
        uint8 d = tokenConfig[token].decimals; // cacheado en setTokenParams()
        if (d == 0) { d = 18; } // fallback defensivo
        return _scaleDecimals(amount, d, CANON_DECIMALS);
    }


    /*//////////////////////////////////////////////////////////////
                          FUNCIONES DE LECTURA
    //////////////////////////////////////////////////////////////*/

    /// @notice Devuelve el balance actual de un usuario para un token específico.
    /// @dev Para ETH nativo, se utiliza address(0) como identificador del token.
    /// @param token Dirección del token (usar address(0) para ETH).
    /// @param user Dirección del usuario titular del saldo.
    /// @return balance Monto almacenado en la bóveda del usuario.
    ///         - En wei si el token es ETH (address(0)).
    ///         - En unidades propias del token ERC-20 si es otro activo.
    function balanceOf(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    /// @notice Devuelve métricas agregadas del sistema para el activo nativo (ETH).
    /// @dev Los valores se expresan en sus unidades naturales:
    ///      - `reservesWei`: total de ETH en bóvedas (wei).
    ///      - `capUsd`: tope global expresado en USD con 8 decimales.
    /// @return reservesWei Total de reservas de ETH en bóvedas (wei).
    /// @return deposits Número total de depósitos realizados en ETH.
    /// @return withdrawals Número total de retiros realizados en ETH.
    /// @return capUsd Tope global del banco en USD (8 decimales) según configuración.
    function statsNative()
        external
        view
        returns (uint256 reservesWei, uint256 deposits, uint256 withdrawals, uint256 capUsd)
    {
        return (totalReservesNative, depositCountNative, withdrawalCountNative, bankCapUsdNative);
    }

    /// @notice Devuelve métricas de configuración y estado para un token ERC-20.
    /// @dev Los valores devueltos se expresan en unidades del token correspondiente.
    ///      Incluye tanto parámetros administrativos como métricas dinámicas de uso.
    /// @param token Dirección del token ERC-20 consultado.
    /// @return reserves Total depositado del token en todas las bóvedas (en unidades del token).
    /// @return cap Tope global configurado para ese token (en unidades del token).
    /// @return threshold Umbral máximo permitido por retiro (en unidades del token).
    /// @return enabled Indica si el token está habilitado para operar (true/false).
    /// @return decimals_ Cantidad de decimales del token (según metadatos ERC-20 o valor cacheado).
    function tokenStats(address token)
        external
        view
        returns (uint256 reserves, uint256 cap, uint256 threshold, bool enabled, uint8 decimals_)
    {
        TokenConfig memory cfg = tokenConfig[token];
        return (totalReservesToken[token], cfg.cap, cfg.threshold, cfg.enabled, cfg.decimals);
    }

    /// @notice Devuelve el balance de un usuario expresado en formato canónico (6 decimales, tipo USDC).
    /// @dev Convierte internamente el saldo real del usuario a la unidad contable estándar definida
    ///      por `CANON_DECIMALS` (por defecto, 6). No modifica almacenamiento ni afecta el balance real.
    ///      Esta función es útil para UIs o métricas donde se requiere comparar montos entre tokens
    ///      con diferentes decimales (p. ej., 18, 8 o 6).
    /// @param token Dirección del token (usar address(0) para ETH nativo).
    /// @param user Dirección del usuario cuya bóveda se consulta.
    /// @return canonicalBalance Monto del usuario convertido a formato canónico (6 decimales).
    function balanceCanonical(address token, address user) 
        external 
        view 
        returns (uint256 canonicalBalance) {
        return _toCanonicalToken(token, balances[token][user]);
    }

    /// @notice Devuelve el total de reservas globales de un token en formato canónico (6 decimales, tipo USDC).
    /// @dev Convierte el total almacenado del token (en sus unidades nativas) al formato estándar
    ///      definido por `CANON_DECIMALS`. En el caso del activo nativo (ETH), se utiliza address(0)
    ///      como identificador del token y se asumen 18 decimales.
    ///      Esta vista es de utilidad para paneles administrativos o dashboards contables.
    /// @param token Dirección del token a consultar (usar address(0) para ETH nativo).
    /// @return canonicalReserves Total de reservas del token convertido a formato canónico (6 decimales).
    function totalReservesCanonical(address token) 
        external 
        view 
        returns (uint256 canonicalReserves) {
        if (token == NATIVE) {
            return _toCanonicalToken(NATIVE, totalReservesNative);
        }
        return _toCanonicalToken(token, totalReservesToken[token]);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         ADMIN: ORÁCULOS Y CAP USD (ETH)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Actualiza el cap USD global para ETH (8 dec). Solo en pausa.
    function setBankCapUsdNative(uint256 newCapUsd)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
    {
        if (newCapUsd == 0) revert ZeroAmount();
        uint256 old = bankCapUsdNative;
        bankCapUsdNative = newCapUsd;
        emit BankCapUsdUpdated(old, newCapUsd);
    }

    /// @notice Actualiza el feed ETH/USD de Chainlink. Solo en pausa.
    function setEthUsdFeed(address newFeed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenPaused
    {
        if (newFeed == address(0)) revert InvalidFeed(newFeed);
        ethUsdFeed = AggregatorV3Interface(newFeed);
        emit EthUsdFeedUpdated(newFeed);
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
        nonReentrant // hooks del receptor
    {
        if (to == address(0)) revert InvalidRecipient();
        token.safeTransferFrom(address(this), to, tokenId);
        emit ERC721Rescued(address(token), tokenId, to);
    }

    /// @notice Rescata tokens ERC1155 enviados por error al contrato.
    /// @dev El contrato debe tener al menos `amount` del id `id`.
    function rescueERC1155(IERC1155 token, uint256 id, uint256 amount, address to, bytes calldata data)
        external
        onlyRole(TREASURER_ROLE)
        whenPaused
        nonReentrant
    {
        if (to == address(0)) revert InvalidRecipient();
        token.safeTransferFrom(address(this), to, id, amount, data);
        emit ERC1155Rescued(address(token), id, amount, to);
    }

    /// @notice Rescata ETH forzado (excedente sobre reservas de usuarios).
    /// @dev Mantiene el invariante: nunca se extrae ETH que respalda `totalReserves`.
    function rescueSurplusNative(address payable to)
        external
        onlyRole(TREASURER_ROLE)
        whenPaused
        nonReentrant
    {
        if (to == address(0)) revert InvalidRecipient();
        uint256 bal = address(this).balance;
        if (bal <= totalReservesNative) return;
        uint256 surplus = bal - totalReservesNative;
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

    /// @notice Convierte wei de ETH a USD (8 dec) usando Chainlink, con cheques de frescura.
    function _weiToUsd(uint256 amountWei) private view returns (uint256 usd8) {
        // Última data del feed ETH/USD
        (
            ,                 // roundId
            int256 price,     // p. ej. 1800.00 * 1e8
            ,                 // startedAt
            uint256 updatedAt,
            
        ) = ethUsdFeed.latestRoundData();

        if (price <= 0) revert InvalidPrice(address(ethUsdFeed));
        if (block.timestamp - updatedAt > priceStaleThreshold) {
            revert StalePrice(address(ethUsdFeed), updatedAt, priceStaleThreshold);
        }

        // Escalas:
        //  - amountWei en 1e18
        //  - price en 1e8 (Chainlink típico)
        //  => usd8 = amountWei * price / 1e18
        usd8 = (amountWei * uint256(price)) / 1e18;
    }
}
