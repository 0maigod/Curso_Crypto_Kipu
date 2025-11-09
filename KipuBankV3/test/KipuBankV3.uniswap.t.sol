// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * KipuBank V3 — Uniswap Integration Tests
 *
 * - Reutiliza el fixture de tu base: KipuBankV3_TestBase (ya deployea el banco y el oráculo).
 * - Usa los mocks existentes en test/utils (ERC20, Router, etc.).
 * - Configura el router/token params respetando ExpectedPause (pause → set → unpause).
 */

import "forge-std/Test.sol";
import {KipuBankV3_TestBase} from "./KipuBankV3.t.base.sol";
import {MockERC20}     from "./utils/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockRouterV2}  from "./utils/MockRouter.sol";

interface IKipuBankV3 {
    function setSwapParams(address router, address weth, address usdc) external;
    function setPathOverride(address token, address[] calldata path) external;
    function pathOverride(address token) external view returns (address[] memory);
    function depositViaSwap(IERC20 tokenIn, uint256 amountIn, uint256 minUsdcOut, uint256 deadline) external;
    function balanceOf(address token, address user) external view returns (uint256);
    function totalReservesToken(address token) external view returns (uint256);
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
}

contract KipuBankV3_Uniswap is KipuBankV3_TestBase {
    MockERC20 private USDC;
    MockERC20 private WETH;
    MockERC20 private DAI;
    MockRouterV2 private router;

    function setUp() public override {
        super.setUp();

        // Deploy mocks de utils
        USDC = new MockERC20("USD Coin", "USDC", 6);
        WETH = new MockERC20("Wrapped Ether", "WETH", 18);
        DAI  = new MockERC20("DAI Stablecoin", "DAI", 18);
        router = new MockRouterV2(address(USDC));

        // setSwapParams requiere paused
        bool wasPaused = bank.paused();
        if (!wasPaused) bank.pause();
        bank.setSwapParams(address(USDC), address(router), address(WETH));
        if (!wasPaused) bank.unpause();

        // Seed y approvals
        DAI.mint(address(this), 1_000_000 ether);
        WETH.mint(address(this), 1_000 ether);
        USDC.mint(address(this), 1_000_000e6);

        DAI.approve(address(bank), type(uint256).max);
        WETH.approve(address(bank), type(uint256).max);
        USDC.approve(address(bank), type(uint256).max);

        // Rates mock
        router.setRate(address(DAI),  2e6);
        router.setRate(address(WETH), 1800e6);
    }

    function test_Uniswap_DepositDAI_SwapsToUSDC_AndCredits() public {
        uint256 amountIn = 1_000 ether;
        uint256 prevVault = USDC.balanceOf(address(bank));

        // 1) Setters admin: siempre en paused
        bool wasPaused = bank.paused();
        if (!wasPaused) bank.pause();

        // swap params (ya lo tenías)
        bank.setSwapParams(address(USDC), address(router), address(WETH));

        // 2) Habilitar USDC en el banco (threshold 0, cap alto, enabled=true)
        //    (si tu firma es distinta, ajusta nombres/orden)
        bank.setTokenParams(address(USDC), 1, type(uint256).max, true);

        // 3) Oráculo fresco (para el check de cap global)
        //    Ajusta los nombres de tu mock si difieren
        feed.setPrice(int256(2_000 * 1e8));        // 1 ETH = 2000 USD
        feed.setUpdatedAt(block.timestamp);

        if (!wasPaused) bank.unpause();

        // el depositante aprobó DAI al banco
        DAI.approve(address(bank), type(uint256).max);

        // MockERC20 implementa IERC20 → se puede pasar DAI directo
        bank.depositViaSwap(DAI, 1_000 ether, 0, block.timestamp + 1 days);

        uint256 credited = USDC.balanceOf(address(bank)) - prevVault;
        assertGt(credited, 0, "Debe acreditar USDC > 0");
    }

    function test_Uniswap_Slippage_RevertsWhenMinOutTooHigh() public {
        router.setRate(address(DAI), 1e3); // salida bajísima
        vm.expectRevert();
        bank.depositViaSwap(DAI, 10_000 ether, 1_000_000e6, block.timestamp + 1 days);
    }

    function test_Uniswap_ZeroOutput_Reverts() public {
        router.setRate(address(DAI), 0);
        vm.expectRevert();
        bank.depositViaSwap(DAI, 100 ether, 0, block.timestamp + 1 days);
    }

}
