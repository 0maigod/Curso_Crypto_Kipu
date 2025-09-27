// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title KipuBank — bóvedas personales de ETH con retiros limitados por transacción y tope global de depósitos.
/// @author Hector Omar Ester
/// @notice Permite a cada usuario depositar ETH en su bóveda y retirarlo con un umbral fijo por transacción.
/// @dev Sigue patrón checks-effects-interactions, usa errores personalizados y evita reentrancy.

contract KipuBank {
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

    /// @notice Cantidad de depósitos por usuario (métrica opcional útil).
    mapping(address => uint64) public depositsBy;

    /// @notice Cantidad de retiros por usuario (métrica opcional útil).
    mapping(address => uint64) public withdrawalsBy;

    /// @dev Flag simple para protección reentrancy.
    uint256 private _locked; // 0 = unlocked, 1 = locked

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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _withdrawThreshold Umbral por retiro (wei).
    /// @param _bankCap Tope global de depósitos (wei).
    constructor(uint256 _withdrawThreshold, uint256 _bankCap) {
        if (_withdrawThreshold == 0 || _bankCap == 0) revert ZeroAmount();
        withdrawThreshold = _withdrawThreshold;
        bankCap = _bankCap;
        _locked = 0;
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFICADORES
    //////////////////////////////////////////////////////////////*/

    /// @dev Evita reentrancy simple para funciones que mueven ETH.
    modifier nonReentrant() {
        if (_locked == 1) revert TransferFailed(); // reutilizamos error genérico
        _locked = 1;
        _;
        _locked = 0;
    }

    /*//////////////////////////////////////////////////////////////
                              FUNCIONES CORE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposita ETH en tu bóveda personal.
    /// @dev Sigue checks-effects-interactions. Emite `Deposit`.
    /// @custom:security Usa nonReentrant para coherencia, aunque no transfiere ETH saliente.
    function deposit() external payable nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        // CHECKS
        uint256 newTotal = totalReserves + amount;
        if (newTotal > bankCap) revert CapExceeded(bankCap, newTotal);

        // EFFECTS
        vault[msg.sender] += amount;
        totalReserves = newTotal;
        unchecked {
            depositCount += 1;
            depositsBy[msg.sender] += 1;
        }

        // INTERACTIONS: no hay
        emit Deposit(msg.sender, amount);
    }

    /// @notice Retira hasta `withdrawThreshold` (o menos) hacia `to`.
    /// @param amount Monto a retirar (wei).
    /// @param to Destinatario del retiro (no puede ser address(0)).
    /// @dev Sigue checks-effects-interactions, emite `Withdrawal`.
    function withdraw(uint256 amount, address payable to) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidRecipient();
        if (amount > withdrawThreshold) revert ThresholdExceeded(amount, withdrawThreshold);

        uint256 balance = vault[msg.sender];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        // EFFECTS
        vault[msg.sender] = balance - amount;
        totalReserves -= amount;
        unchecked {
            withdrawalCount += 1;
            withdrawalsBy[msg.sender] += 1;
        }

        // INTERACTIONS
        _safeTransferNative(to, amount);

        emit Withdrawal(msg.sender, to, amount);
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

    /*//////////////////////////////////////////////////////////////
                         FUNCIONES DE RESCATE / SEGURIDAD
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
