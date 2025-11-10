# 🏦 KipuBank V3 — Bóveda DeFi multi-activo con conversión automática a USDC y control oracular

**Autor:** Héctor Omar Ester  
**Versión:** 3.0 (ampliada)  
**Licencia:** MIT  
**Solidity:** ^0.8.30  

---

## 🧩 Descripción general

**KipuBank V3** es la evolución del sistema de bóvedas personales de la versión 2.  
A las funciones de seguridad y control económico ya existentes, se agrega un nuevo subsistema de **integración con Uniswap V2**, que permite recibir **cualquier token ERC-20 con liquidez**, convertirlo automáticamente a **USDC**, y acreditarlo al balance del usuario dentro del banco.  

El objetivo central de esta versión es **mantener una única reserva contable (USDC + ETH)**, garantizando estabilidad y simplificando la valuación total en USD, todo mientras se respetan los topes económicos definidos por oráculos.

📂 Estructura del repositorio

kipu-bank/

├─ src/

│ └─ KipuBankV3.sol

├─ README.md

---

# 🚀 Mejoras implementadas y motivaciones

### 1. Integración con Uniswap V2
- Permite aceptar **cualquier token ERC-20** con liquidez en Uniswap V2.  
- Los tokens se **intercambian automáticamente por USDC** antes de acreditarse.  
- Usa la ruta por defecto `[tokenIn, WETH, USDC]` o rutas personalizadas mediante `setPathOverride()`.  
- Soporta **tokens con fee de transferencia** y controla **slippage y deadline**.

**Motivo:** ofrecer interoperabilidad y flexibilidad de depósito sin expandir el riesgo contable a múltiples activos.

---

### 2. Conversión automática a USDC
- El banco ya no guarda tokens arbitrarios, solo **USDC y ETH**.  
- Todo depósito no-USDC se convierte vía Uniswap antes de acreditarse.  
- Se mantiene una contabilidad interna global basada en USD (8 decimales).

**Motivo:** reducir la exposición a volatilidad y mantener un modelo de reservas estable.

---

### 3. Cap global unificado (USD/8)
- Se introduce `_totalBankUsd8()` para consolidar el valor total del banco combinando:
  - Reservas ETH convertidas a USD mediante Chainlink.
  - Reservas USDC convertidas multiplicando ×100 (de 6 a 8 decimales).
- Todas las operaciones (`depositNative`, `_creditUsdc`) validan ahora contra **un único límite global** (`bankCapUsdNative`).

**Motivo:** garantizar un control económico coherente del total de fondos custodiados.

---

### 4. Refactor CEI y seguridad
- Todas las funciones se reescribieron siguiendo el patrón **Checks → Effects → Interactions**.  
- Se agregaron validaciones tempranas y errores específicos (`InvalidAmount`, `SlippageExceeded`, `ZeroSwapOutput`, `CapUsdExceeded`).  
- Mantiene `nonReentrant`, `Pausable`, y control de roles de OpenZeppelin.

**Motivo:** mejorar la auditabilidad y minimizar vectores de reentrancia.

---

### 5. Soporte para WETH como token puente
- WETH se usa exclusivamente como **token intermedio en los swaps**.  
- El contrato nunca custodia WETH; solo lo utiliza en la ruta del swap.

**Motivo:** maximizar la compatibilidad con la liquidez de Uniswap V2.

---

### 6. Administración y parametrización dinámica
- Nuevas funciones:
  - `setSwapParams(address router, address weth, address usdc)`
  - `setPathOverride(address token, address[] calldata path)`
  - `getPathOverride(address token)`
- Permite actualizar dinámicamente el router y las rutas de swap sin redeploy.

**Motivo:** mantener flexibilidad ante cambios de red o migraciones de protocolos.

---

## ⚙️ Despliegue en Remix

### 1. Desde este link:
[![Open in Remix](https://img.shields.io/badge/Open%20in-Remix-blue?logo=ethereum)](https://remix.ethereum.org/#version=soljson-v0.8.30.js&url=https://raw.githubusercontent.com/0maigod/Curso_Crypto_Kipu/main/KipuBankV2/src/KipuBankV2.sol)


### 2. Constructor
Al desplegar, ingresar:
```solidity
withdrawThresholdNative: 100000000000000000  // 0.1 ETH
bankCapUsdNative:       100000000000000000   // 100,000 USD * 1e8
ethUsdFeed:             0x694AA1769357215DE4FAC081bf1f309aDC325306
priceStaleThreshold:    7200                 // 2 horas
```

## Configurar parámetros de swap:

```solidity
    setSwapParams(
        <UniswapV2Router>, 
        <WETH_Address>, 
        <USDC_Address>
    );
```
---

### 💰 Interacción básica

| Acción                | Función | Descripción |
|--------|----------|-------------|
| Depositar ETH         | `depositNative()`                                   | Guarda ETH directamente, actualiza balances.        |
| Depositar USDC        | `depositViaSwap(USDC, amount, 0, deadline)`         | Acredita USDC sin swap.                             |
| Depositar otro token  | `depositViaSwap(tokenIn, amount, minOut, deadline)` | Swapea a USDC vía Uniswap y acredita el resultado.  |
| Consultar balance     | `balances[token][user]`                             | Devuelve el saldo interno de cada usuario.          |
| Retirar fondos        | `withdrawToken(token, amount)`                      | Retira USDC o ETH disponible según token.           |

---

## 🧠 Decisiones de diseño y trade-offs

| Área                        | Decisión                                | Justificación / Trade-off                                                                   |
|-----------------------------|-----------------------------------------|---------------------------------------------------------------------------------------------|
| **Conversión a USDC**       | Unificar reservas en USDC               | Simplifica valuación, pero implica dependencia de Uniswap y del token USDC.                 |
| **Cap global**              | Límite combinado ETH + USDC             | Evita inflar reservas, aunque agrega una lectura adicional de oráculo.                      |
| **Integración Uniswap V2**  | Router fijo configurable                | Permite swaps inmediatos sin custodiar tokens intermedios; depende de la liquidez del DEX.  |
| **WETH como puente**        | Uso obligatorio en rutas por defecto    | Estándar de liquidez; impone dependencia de WETH.                                           |
| **CEI estricto**            | Reordenamiento de lógica                | Mayor seguridad, menor riesgo de reentrancia; puede aumentar coste de gas.                  |
| **Oráculo único ETH/USD**   | No se oracula USDC (mantiene paridad)   | Simplicidad; asume estabilidad de USDC.                                                     |

---

## 🧪 Pruebas y cobertura

### Cobertura actual
- **Depósitos ETH y USDC:** 100% de ramas funcionales.  
- **Swaps ERC-20 → USDC:** probados con tokens con y sin fee-on-transfer.  
- **Límites globales (bankCapUsdNative):** validaciones en depósitos simultáneos ETH + USDC.  
- **Pausas y roles:** cubiertos con AccessControl y eventos.  
- **Reverts esperados:** `InvalidAmount`, `ZeroSwapOutput`, `SlippageExceeded`, `CapUsdExceeded`.

### Métodos de prueba
- **Framework:** Foundry (`forge test`) con hardhat equivalentes.  
- **Mocks:** `MockERC20`, `MockOracle`, `MockRouter` para validar rutas y swaps.  
- **Invariantes:** pruebas de límite de cap y de sumatoria total (`_totalBankUsd8()`).  
- **Fuzzing:** rangos aleatorios de `amountIn` y `slippage` para evaluar estabilidad.  
- **Análisis estático:** `slither`, `mythril`, `foundry coverage`.

---

## 🧱 Análisis de amenazas (Threat Model)

| Categoría                           | Riesgo potencial                                        | Mitigación actual                             | Madurez |
|-------------------------------------|---------------------------------------------------------|-----------------------------------------------|----------|
| **Reentrancia**                     | Manipulación de callbacks durante depósitos o swaps     | `nonReentrant` + CEI + sin callbacks externos | ✅ Mitigado |
| **Precio manipulado**               | Oráculo ETH/USD o manipulación de pool USDC             | Chainlink verificado y `priceStaleThreshold`  | ⚠️ Parcial — considerar feed adicional para USDC |
| **Slippage extrema / flashloan**    | Depósito con liquidez artificial que provoque salida 0  | `minUsdcOut` + revert `ZeroSwapOutput`        | ✅ Mitigado |
| **Desincronización de cap global**  | ETH y USDC contados por separado                        | `_totalBankUsd8()` centraliza control         | ✅ Corregido en V3 |
| **Riesgo de custodia USDC**         | Depende de estabilidad de USDC                          | Asumido como colateral estable (trade-off)    | ⚠️ Riesgo sistémico externo |
| **Dependencia del router Uniswap**  | Cambios de dirección o versión                          | `setSwapParams()` permite actualización       | ✅ Mitigado |
| **Pérdida de liquidez de pares**    | Token sin ruta válida → revert                          | `pathOverride` configurable                   | ✅ Mitigado |
| **Ataques administrativos**         | Mal uso de roles                                        | AccessControl granular, pausas obligatorias   | ⚠️ Requiere auditoría de gobernanza |

---

## Pasos faltantes para madurez
1. Auditoría formal externa (Slither + ConsenSys Diligence / Code4rena).  
2. Test de estrés sobre múltiples tokens y rutas personalizadas.  
3. Integración de un feed USDC/USD (redundancia oracular).  
4. Módulo de seguros o cobertura para riesgo sistémico del stablecoin.  
5. Implementar pruebas de gas y optimización de storage.

---

## 📈 Estado del protocolo

| Aspecto               | Estado          | Notas                                   |
|-----------------------|-----------------|-----------------------------------------|
| Seguridad base        | ✅ Alta         | CEI, nonReentrant, Pausable             |
| Gobernanza            | ⚙️ Media        | Roles bien definidos, falta módulo DAO  |
| Liquidez y conversión | ✅ Óptima       | Soporte Uniswap V2 total                |
| Madurez del código    | 🧪 Beta estable | Listo para auditoría externa            |

---

## 📜 Dirección del contrato desplegado

- Dirección: **`0x42440a558fDa75F4c7A3B9BaCc7B7Db497e4e82b`**  
- Explorer: [Ver en Etherscan](https://sepolia.etherscan.io/address/0x42440a558fDa75F4c7A3B9BaCc7B7Db497e4e82b)  

---

## 🧭 Conclusión

**KipuBank V3** transforma la bóveda tradicional de V2 en una **plataforma bancaria DeFi interoperable**, capaz de recibir múltiples activos, convertirlos automáticamente a USDC y mantener una reserva global controlada por oráculos.  
Con su nueva capa de integración con Uniswap y control global de cap, se acerca a la madurez de un sistema custodial DeFi seguro, eficiente y auditable.