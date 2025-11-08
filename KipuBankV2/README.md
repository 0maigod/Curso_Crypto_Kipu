# 🏦 KipuBank V2 — Bóvedas personales multi-activo con límites y control oracular

**Autor:** Héctor Omar Ester  
**Versión:** 2.0 (ampliada)  
**Licencia:** MIT  
**Solidity:** ^0.8.30  

---

## 🧩 Descripción general

**KipuBank V2** es una evolución del contrato base `KipuBank`, diseñado como una **bóveda personal de activos nativos y ERC-20** que incorpora controles administrativos, límites dinámicos en USD mediante oráculos de Chainlink y mecanismos de seguridad estándar en DeFi.

Cada usuario puede depositar y retirar ETH o tokens ERC-20 hacia/desde su propia bóveda con **umbral máximo por retiro** y **tope global configurable** (cap).  
El contrato aplica los patrones de seguridad y eficiencia recomendados por la comunidad Ethereum: *checks-effects-interactions*, `nonReentrant`, `Pausable`, y control de acceso basado en roles.

📂 Estructura del repositorio

kipu-bank/

├─ src/

│ └─ KipuBankV2.sol

├─ README.md

---

## 🚀 Mejoras introducidas

### 1. Control de acceso (roles)
- Integración de **AccessControl** de OpenZeppelin.
- Roles principales:
  - `DEFAULT_ADMIN_ROLE`: puede otorgar o revocar otros roles.
  - `PAUSER_ROLE`: puede pausar/despausar operaciones.
  - `TREASURER_ROLE`: autorizado para rescates y mantenimiento de fondos.

**Motivo:** separar responsabilidades y reducir superficie de ataque; permite gobernanza multi-firma o distribución de permisos.

---

### 2. Modo de pausa (`Pausable`)
- Las operaciones de usuario (`deposit`, `withdraw`) están protegidas por `whenNotPaused`.
- Las funciones administrativas sensibles (ej. configuración de tokens) solo pueden ejecutarse `whenPaused`.

**Motivo:** detener el sistema ante un incidente o auditoría, evitando movimientos de fondos mientras se corrige un error.

---

### 3. Contabilidad multi-token
- Soporte para depósitos y retiros de **tokens ERC-20**, además de ETH.
- Cada token tiene su propia configuración:
  - `threshold` (umbral por retiro),
  - `cap` (tope global de depósitos),
  - `enabled` (estado operativo),
  - `decimals` (cacheado automáticamente).
- ETH usa `address(0)` como identificador.

**Motivo:** unificar la lógica de bóvedas para múltiples activos sin duplicar contratos.

---

### 4. Integración con oráculos Chainlink
- Usa el **feed ETH/USD** para calcular el valor total de reservas en USD.
- Los límites globales (`bankCapUsdNative`) se expresan en **USD (8 decimales)**.
- El sistema verifica:
  - `InvalidFeed` si el oráculo no es válido.
  - `InvalidPrice` si el precio ≤ 0.
  - `StalePrice` si el dato está vencido según `priceStaleThreshold`.

**Motivo:** permitir límites económicos basados en valor real, no solo cantidad de ETH.

---

### 5. Rescate de activos (solo `TREASURER_ROLE`)
- Funciones de rescate seguras para:
  - `rescueERC20`
  - `rescueERC721`
  - `rescueERC1155`
  - `rescueSurplusNative` (para ETH forzado vía `selfdestruct`)
- Solo disponibles en modo **pausado**.

**Motivo:** evitar bloqueos de fondos accidentales sin exponer riesgo de rug pull.

---

### 6. Conversión de decimales y unidad canónica (USDC-like)
- Las métricas y límites se normalizan a una **unidad de contabilidad estándar de 6 decimales** (similar a USDC).
- Se mantienen los balances internos en sus unidades nativas.
- Funciones de ayuda (`_scaleDecimals`, `_toCanonicalToken`, etc.) permiten convertir on-the-fly.

**Motivo:** uniformidad contable y compatibilidad con UIs y protocolos que operan en formato USD/USDC.

---

### 7. Seguridad y eficiencia
- Uso del patrón **checks-effects-interactions** en todas las operaciones.
- Protección `nonReentrant`.
- Validaciones tempranas (`ZeroAmount`, `InvalidRecipient`, etc.) antes de leer storage.
- Uso de `immutable` y `constant` para variables inmutables.
- `unchecked` en contadores donde no hay riesgo real de overflow.

**Motivo:** minimizar gas y exposición a vulnerabilidades comunes (reentrancy, overflow, fallos de transferencia).

---

## ⚙️ Despliegue en Remix

### 1. Desde este link:
[![Open in Remix](https://img.shields.io/badge/Open%20in-Remix-blue?logo=ethereum)](https://remix.ethereum.org/#version=soljson-v0.8.30.js&url=https://raw.githubusercontent.com/0maigod/Curso_Crypto_Kipu/main/KipuBankV2/src/KipuBankV2.sol)


### 2. Constructor
Al desplegar, ingresar:
```solidity
withdrawThresholdNative: 100000000000000000  // 0.1 ETH
bankCapUsdNative:       100000000000000000   // 100,000 USD * 1e8
ethUsdFeed:             <dirección del feed ETH/USD>
priceStaleThreshold:    7200                 // 2 horas

---

## 📜 Dirección del contrato desplegado

- Dirección: **`0xD9C3A26E45f7103317bF508b8CA9E3f7E22e91f7`**  
- Explorer: [Ver en Etherscan](https://sepolia.etherscan.io/address/0xD9C3A26E45f7103317bF508b8CA9E3f7E22e91f7)  

---
