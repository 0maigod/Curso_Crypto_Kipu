// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/// @notice Mock minimal de un AggregatorV3 (Chainlink) para ETH/USD.
/// Devuelve un precio con 8 decimales y permite ajustar `updatedAt` y el precio.
contract MockEthUsdFeed {
    int256  private _answer;     // precio con 8 decimales (p.ej. 3000e8)
    uint8   private _decimals;   // 8 por convención Chainlink ETH/USD
    uint256 private _updatedAt;

    constructor(int256 priceAnswer8) {
        _answer    = priceAnswer8;      // ej: 3_000e8
        _decimals  = 8;
        _updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @dev Firma compatible con Chainlink: (roundId, answer, startedAt, updatedAt, answeredInRound)
    function latestRoundData()
        external
        view
        returns (
            uint80,
            int256,
            uint256,
            uint256,
            uint80
        )
    {
        return (0, _answer, block.timestamp, _updatedAt, 0);
    }

    // ---- Helpers para tests ----

    function setUpdatedAt(uint256 t) external {
        _updatedAt = t;
    }

    function setPrice(int256 p) external {
        _answer = p;
    }

    function description() external pure returns (string memory) { return "MOCK ETH/USD"; }
    function version() external pure returns (uint256) { return 1; }
}
