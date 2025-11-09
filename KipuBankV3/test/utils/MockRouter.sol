// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract MockRouterV2 {
    // tokenIn => USDC per tokenIn (scaled to USDC decimals already)
    mapping(address => uint256) public usdcPerTokenIn;
    address public immutable usdc;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function setRate(address tokenIn, uint256 usdcPerUnit) external {
        // Example: if 1 tokenIn -> 2 USDC (6 dec), set usdcPerUnit = 2e6
        usdcPerTokenIn[tokenIn] = usdcPerUnit;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint /*amountOutMin*/,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external {
        address tokenIn = path[0];
        // Pull tokens from msg.sender
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull fail");

        // Mint USDC to recipient according to rate
        uint256 rate = usdcPerTokenIn[tokenIn];
        uint256 out = rate * amountIn / 1e18; // assume tokenIn has 18 decimals in tests unless overridden
        // If tokenIn is USDC itself, we just forward amountIn
        if (tokenIn == usdc) {
            out = amountIn;
        }

        IMintable(usdc).mint(to, out);
    }
}
