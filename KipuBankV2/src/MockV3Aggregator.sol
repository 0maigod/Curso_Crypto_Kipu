// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Interfaz mínima de Chainlink que tu contrato espera.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @notice Mock simple y controlable del feed ETH/USD
contract MockV3Aggregator is AggregatorV3Interface {
    uint8 private _decimals;
    string private _description;
    uint256 private _version;

    // Datos de la ronda "latest"
    uint80 private _roundId;
    int256 private _answer;       // precio con _decimals decimales (p. ej. 8)
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    constructor(
        uint8 decimals_,
        int256 initialAnswer,      // p. ej. 3000 * 1e8 = 300000000000
        string memory description_
    ) {
        _decimals = decimals_;
        _answer = initialAnswer;
        _description = description_;
        _version = 1;
        _roundId = 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
    }

    // ====== Setters para test ======

    /// @notice Cambia el precio y opcionalmente la marca de tiempo.
    function setPrice(int256 newAnswer, uint256 newUpdatedAt) external {
        _answer = newAnswer;
        _updatedAt = newUpdatedAt == 0 ? block.timestamp : newUpdatedAt;
        _roundId += 1;
        _answeredInRound = _roundId;
        _startedAt = _updatedAt;
    }

    /// @notice Marca el precio como "stale" seteando un updatedAt viejo.
    function makePriceStale(uint256 secondsOld) external {
        require(secondsOld > 0, "secondsOld=0");
        _updatedAt = block.timestamp - secondsOld;
    }

    /// @notice Por si querés simular otra cantidad de decimales.
    function setDecimals(uint8 d) external { _decimals = d; }

    // ====== Implementación de la interfaz ======
    function decimals() external view override returns (uint8) { return _decimals; }
    function description() external view override returns (string memory) { return _description; }
    function version() external view override returns (uint256) { return _version; }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
