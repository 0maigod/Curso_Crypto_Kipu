// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import { KipuBankV3_TestBase } from "./KipuBankV3.t.base.sol";

contract KipuBankV3_BasicTest is KipuBankV3_TestBase {
    /* Constructor & estado inicial */
    function test_constructor_initial_state() public view{
        (uint256 reserves,,,) = bank.statsNative();
        assertEq(reserves, 0);
        assertFalse(bank.paused());
    }

    /* Access control */
    function test_onlyOwner_can_pause_unpause() public {
        address alice = address(0xA11CE);
        vm.prank(alice);
        vm.expectRevert(); // Ownable
        bank.pause();

        bank.pause();
        assertTrue(bank.paused());

        vm.prank(alice);
        vm.expectRevert();
        bank.unpause();

        bank.unpause();
        assertFalse(bank.paused());
    }

    /* Depósito nativo */
    function test_depositNative_updatesBalancesAndReserves() public {
        vm.prank(USER);
        bank.depositNative{value: 1 ether}();

        (uint256 reserves, uint256 deposits, uint256 withdrawals, uint256 capUsd) = bank.statsNative();
        assertEq(reserves, 1 ether);
        assertEq(deposits, 1);
        assertEq(withdrawals, 0);
        assertEq(capUsd, CAP_USD_8);

        assertEq(bank.balanceOf(address(0), USER), 1 ether);
    }

    /* Retiro con threshold */
    function test_withdrawNative_respectsThresholdAndBalance() public {
        vm.prank(USER);
        bank.depositNative{value: 1 ether}();

        vm.prank(USER);
        vm.expectRevert();
        bank.withdrawNative(WITHDRAW_THRESHOLD + 1, payable(USER));

        vm.prank(USER);
        bank.withdrawNative(WITHDRAW_THRESHOLD, payable(USER));

        assertEq(bank.balanceOf(address(0), USER), 0.5 ether);
        (uint256 reserves,, uint256 withdrawals,) = bank.statsNative();
        assertEq(reserves, 0.5 ether);
        assertEq(withdrawals, 1);
    }

    /* Pausable */
    function test_pause_blocksDepositAndUnpauseAllows() public {
        bank.pause();

        vm.prank(USER);
        vm.expectRevert();
        bank.depositNative{value: 0.1 ether}();

        bank.unpause();
        vm.prank(USER);
        bank.depositNative{value: 0.1 ether}();
        assertEq(bank.balanceOf(address(0), USER), 0.1 ether);
    }

    /* Errores de entrada mínimos */
    function test_depositNative_zero_amount_reverts() public {
        vm.prank(USER);
        vm.expectRevert();
        bank.depositNative{value: 0}();
    }

    function test_withdrawNative_invalid_recipient_reverts() public {
        vm.prank(USER);
        bank.depositNative{value: 1 ether}();

        vm.prank(USER);
        vm.expectRevert();
        bank.withdrawNative(0.1 ether, payable(address(0)));
    }
}
