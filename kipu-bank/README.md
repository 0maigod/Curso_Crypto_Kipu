# KipuBank

KipuBank es un contrato inteligente en Solidity que permite a los usuarios depositar y retirar ETH en una bóveda personal, con ciertas restricciones y límites de seguridad.  
Fue desarrollado siguiendo buenas prácticas de seguridad y documentado con NatSpec.

---

## ✨ Características principales

- Cada usuario tiene una bóveda personal para almacenar ETH.
- Se pueden realizar depósitos con la función `deposit()`.
- Los retiros están limitados por transacción a un umbral fijo (`withdrawThreshold`)(`100000000000000000 = 0.1 ETH`).
- Existe un límite global de depósitos (`bankCap`)(`5000000000000000000 = 5 ETH`).
- Se emiten eventos en cada depósito (`Deposit`) y retiro (`Withdrawal`).
- Se llevan contadores de número de depósitos y retiros (globales y por usuario).
- Errores personalizados en lugar de `require` con strings.
- Seguridad:
  - Patrón Checks-Effects-Interactions.
  - Protección contra reentrancy.
  - Transferencias nativas con `call` y verificación de éxito.
  - `receive` y `fallback` bloqueados para evitar depósitos directos.

---

## 📂 Estructura del repositorio

    kipu-bank/
    ├─ contracts/
    │ └─ KipuBank.sol
    ├─ README.md

---

## 🚀 Despliegue del contrato

Este proyecto se desplegó usando **Remix + Metamask**.

1. Abre [Remix IDE](https://remix.ethereum.org/).
2. Crea la carpeta `contracts/` y añade el archivo `KipuBank.sol`.
3. Compila con la versión `0.8.30`.
4. Conecta Metamask (modo `Injected Provider`).
5. Selecciona la red de testnet (ej. Sepolia).
6. Despliega el contrato ingresando los parámetros del constructor:
   - `_withdrawThreshold` → umbral de retiro por transacción (en wei).
   - `_bankCap` → límite global de depósitos (en wei).
7. Confirma en Metamask y copia la dirección del contrato.

---

## 🔎 Verificación en block explorer

1. Ve a [Etherscan Sepolia](https://sepolia.etherscan.io/)
2. Ingresa la dirección de tu contrato.
3. Haz clic en **Verify and Publish**.
4. Elige:
   - Compiler: `0.8.30`
   - License: `MIT`
5. Pega el código de `KipuBank.sol` y confirma.

---

## 📜 Dirección del contrato desplegado

- Dirección: **`0xbEbEe94302Ad793c060b3Bb2eF670dA3232fDE49`**  
- Explorer: [Ver en Etherscan](https://sepolia.etherscan.io/address/0xbEbEe94302Ad793c060b3Bb2eF670dA3232fDE49)  

---

## ⚙️ Cómo interactuar

Una vez verificado el contrato, puedes interactuar directamente desde el **explorer** (pestaña *Write Contract* y *Read Contract*).

### Funciones principales

- **Depositar ETH**
  - `deposit()` (marcar `payable` y enviar `msg.value`).
- **Retirar ETH**
  - `withdraw(amount, to)` → Retira hasta el límite `withdrawThreshold` hacia la dirección `to`.
- **Consultar balance**
  - `balanceOf(user)` devuelve el balance en wei.
- **Consultar estadísticas**
  - `stats()` devuelve información agregada (total, depósitos, retiros, cap, threshold).

---

## 👨‍💻 Autor

- Alumno: *Héctor Omar Ester*  
- Proyecto: **KipuBank**  

