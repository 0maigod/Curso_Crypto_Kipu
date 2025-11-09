// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockOracle {
    int256 public price; // 8 decimals (USD*1e8)
    uint256 public updatedAt;
    uint80 public roundId = 1;

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
        roundId++;
    }

    // Chainlink-style interface subset
    function latestRoundData() external view returns (
        uint80,
        int256,
        uint256,
        uint256,
        uint80
    ) {
        return (roundId, price, 0, updatedAt, roundId);
    }
}
