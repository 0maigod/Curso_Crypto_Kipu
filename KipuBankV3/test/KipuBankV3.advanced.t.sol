// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import { KipuBankV3 } from "../src/KipuBankV3.sol";
import { KipuBankV3_TestBase } from "./KipuBankV3.t.base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./utils/MockERC20.sol";


contract Reenterer {
    KipuBankV3 public bank;
    constructor(KipuBankV3 _bank) { bank = _bank; }

    receive() external payable {
        try bank.depositNative{value: 0.01 ether}() {} catch {}
    }
}

contract KipuBankV3_AdvancedTest is KipuBankV3_TestBase {
    /* Stale price */
    function test_depositNative_reverts_whenPriceIsStale() public {
        vm.warp(10 days);
        feed.setUpdatedAt(block.timestamp - STALE_THRESHOLD - 1);

        vm.prank(USER);
        vm.expectRevert();
        bank.depositNative{value: 0.1 ether}();
    }

    function test_depositNative_works_again_whenPriceFresh() public {
        vm.warp(10 days);
        feed.setUpdatedAt(block.timestamp - STALE_THRESHOLD - 1);
        vm.prank(USER);
        vm.expectRevert();
        bank.depositNative{value: 0.1 ether}();

        feed.setUpdatedAt(block.timestamp);
        vm.prank(USER);
        bank.depositNative{value: 0.1 ether}();

        (uint256 reserves, uint256 deposits,,) = bank.statsNative();
        assertEq(reserves, 0.1 ether);
        assertEq(deposits, 1);
    }

    /* Invalid price */
    function test_depositNative_invalid_price_reverts() public {
        vm.warp(10 days);
        feed.setPrice(0); // o negativo si querés
        vm.prank(USER);
        vm.expectRevert();
        bank.depositNative{value: 0.1 ether}();
    }

    /* Cap USD */
    function test_depositNative_exceeds_cap_reverts() public {
        // Asegurá precio fresco (evita revert por stale)
        makePriceFresh(); // helper de la base (warp + updatedAt)

        // Poné un CAP bien bajo en USD (requiere admin y generalmente estar pausado)
        bank.pause();
        // Ajustá el nombre del setter si es distinto en tu contrato:
        bank.setBankCapUsdNative(1_000e8); // USD 1,000 (8 decimales)
        bank.unpause();

        // A 3000e8 USD/ETH, 1 ETH = 3,000 USD > 1,000 USD → debe revertir por CapUsdExceeded
        vm.prank(USER);
        vm.expectRevert();
        bank.depositNative{ value: 1 ether }();
    }

    /* Estadísticas tras múltiples ops */
    function test_statsNative_after_multiple_ops() public {
        vm.prank(USER);
        bank.depositNative{value: 1 ether}();

        vm.prank(USER);
        bank.withdrawNative(0.25 ether, payable(USER));

        vm.prank(USER);
        bank.depositNative{value: 0.75 ether}();

        (uint256 reserves, uint256 deposits, uint256 withdrawals, uint256 capUsd) = bank.statsNative();
        assertEq(reserves, 1.5 ether);
        assertEq(deposits, 2);
        assertEq(withdrawals, 1);
        assertEq(capUsd, CAP_USD_8);
    }

    /* Reentrancy */
    function test_reentrancy_blocked_on_withdraw() public {
        Reenterer atk = new Reenterer(bank);
        vm.deal(address(atk), 1 ether);

        vm.prank(address(atk));
        bank.depositNative{value: 0.5 ether}();

        vm.expectRevert();
        bank.withdrawNative(0.1 ether, payable(address(atk)));
    }

    function test_erc20_deposit_withdraw_basic() public {
        // 1) Mock y fondos
        MockERC20 mock = new MockERC20("Mock Token", "MCK", 18);
        mock.mint(USER, 1_000 ether);

        // 2) Habilitar token en el banco (requiere estar pausado y rol admin: el deployer lo tiene)
        bank.pause();
        // threshold alto (p.ej. 1_000 ether), cap alto
        bank.setTokenParams(address(mock), 1_000 ether, type(uint256).max, true);
        bank.unpause();

        // 3) Aprobar y depositar (usar IERC20)
        IERC20 itoken = IERC20(address(mock));

        vm.prank(USER);
        itoken.approve(address(bank), 100 ether);

        vm.prank(USER);
        bank.depositToken(itoken, 100 ether);

        assertEq(mock.balanceOf(address(bank)), 100 ether);

        // 4) Retirar (firma también con IERC20)
        vm.prank(USER);
        bank.withdrawToken(itoken, 40 ether, USER);

        assertEq(mock.balanceOf(address(bank)), 60 ether);
        assertEq(mock.balanceOf(USER), 1_000 ether - 100 ether + 40 ether);
    }


}
