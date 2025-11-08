// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {MockEthUsdFeed} from "./utils/MockEthUsdFeed.sol";
// (Opcional para tests ERC20 en el avanzado)
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title KipuBankV3_TestBase
 * @dev Fixture base compartida para todos los tests.
 * - Despliega un Mock del feed ETH/USD (8 decimales)
 * - Despliega KipuBankV3 con parámetros razonables
 * - Fondea una cuenta USER para pruebas
 * - Expone helpers útiles para advanced tests
 */
abstract contract KipuBankV3_TestBase is Test {
    // --------- Constantes comunes (ajustá si querés) ----------
    uint256 internal constant WITHDRAW_THRESHOLD = 0.5 ether;
    uint256 internal constant CAP_USD_8         = 1_000_000e8; // tope en USD con 8 decimales
    uint256 internal constant STALE_THRESHOLD   = 2 hours;

    address internal constant USER = address(0xBEEF);

    // --------- Estado común ----------
    KipuBankV3 internal bank;
    MockEthUsdFeed internal feed;

    // --------- Setup ----------
    function setUp() public virtual {
        // Precio ETH/USD = 3000 con 8 decimales
        feed = new MockEthUsdFeed(3_000e8);

        // Despliegue del banco con el feed mock
        bank = new KipuBankV3(
            WITHDRAW_THRESHOLD,
            CAP_USD_8,
            address(feed),
            STALE_THRESHOLD
        );

        // Fondos para el usuario de prueba
        vm.deal(USER, 10 ether);
    }

    // =========================================================
    // ===================== HELPERS ===========================
    // =========================================================

    /// @notice Avanza el tiempo de forma segura para evitar underflows al testear stale price.
    function warpSafe(uint256 secs) internal {
        // p.ej., warpSafe(10 days);
        vm.warp(secs);
    }

    /// @notice Fuerza el feed a estar "stale" (vencido) respecto del STALE_THRESHOLD actual.
    function makePriceStale() internal {
        // Aseguramos timestamp grande
        if (block.timestamp < 10 days) vm.warp(10 days);
        feed.setUpdatedAt(block.timestamp - STALE_THRESHOLD - 1);
    }

    /// @notice Refresca el feed (precio “fresco”).
    function makePriceFresh() internal {
        if (block.timestamp < 10 days) vm.warp(10 days);
        feed.setUpdatedAt(block.timestamp);
    }

    /// @notice Helper para configurar tokens ERC-20 en el banco (si usás tests avanzados con ERC-20).
    /// @dev KipuBankV3 exige estar pausado y rol admin para setear parámetros.
    function configureToken(address token, uint256 threshold, uint256 cap, bool enabled) internal {
        // El deployer (este contrato de test) tiene DEFAULT_ADMIN_ROLE
        bool wasPaused = bank.paused();
        if (!wasPaused) bank.pause();
        bank.setTokenParams(token, threshold, cap, enabled);
        if (!wasPaused) bank.unpause();
    }
}
