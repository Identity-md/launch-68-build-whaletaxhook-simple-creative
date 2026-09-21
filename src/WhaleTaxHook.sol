// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice A dynamic-fee hook charging `whaleFee` when |amountSpecified| is over 1% of active liquidity.
/// @dev Swap size is the caller's specified amount, for both exact-input and exact-output swaps.
contract WhaleTaxHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error PoolMustUseThisHook();
    error PoolMustUseDynamicFee();
    error PoolNotRegistered();
    error WhaleFeeMustExceedBaseFee();

    IPoolManager public immutable poolManager;
    uint24 public immutable baseFee;
    uint24 public immutable whaleFee;

    mapping(PoolId poolId => bool registered) public isPoolRegistered;

    constructor(IPoolManager manager_, uint24 baseFee_, uint24 whaleFee_) {
        if (baseFee_ > LPFeeLibrary.MAX_LP_FEE) revert LPFeeLibrary.LPFeeTooLarge(baseFee_);
        if (whaleFee_ > LPFeeLibrary.MAX_LP_FEE) revert LPFeeLibrary.LPFeeTooLarge(whaleFee_);
        if (whaleFee_ <= baseFee_) revert WhaleFeeMustExceedBaseFee();

        poolManager = manager_;
        baseFee = baseFee_;
        whaleFee = whaleFee_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (address(key.hooks) != address(this)) revert PoolMustUseThisHook();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert PoolMustUseDynamicFee();

        PoolId id = key.toId();
        isPoolRegistered[id] = true;
        poolManager.updateDynamicLPFee(key, baseFee);
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (!isPoolRegistered[id]) revert PoolNotRegistered();
        uint24 fee = _feeFor(id, params.amountSpecified);
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Current one-percent cutoff for a registered pool.
    function threshold(PoolKey calldata key) external view returns (uint256) {
        PoolId id = key.toId();
        if (!isPoolRegistered[id]) revert PoolNotRegistered();
        return uint256(poolManager.getLiquidity(id)) / 100;
    }

    /// @notice Quotes the fee from current manager liquidity; equality pays the base fee.
    function previewFee(PoolKey calldata key, int256 amountSpecified)
        external
        view
        returns (uint24)
    {
        PoolId id = key.toId();
        if (!isPoolRegistered[id]) revert PoolNotRegistered();
        return _feeFor(id, amountSpecified);
    }

    function _feeFor(PoolId id, int256 amountSpecified) private view returns (uint24) {
        uint256 magnitude;
        assembly ("memory-safe") {
            let mask := sar(255, amountSpecified)
            magnitude := sub(xor(amountSpecified, mask), mask)
        }
        return magnitude > uint256(poolManager.getLiquidity(id)) / 100 ? whaleFee : baseFee;
    }

    // Disabled IHooks callbacks deliberately revert, including when called by the manager.
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        v4_core_ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        v4_core_ModifyLiquidityParams calldata,
        v4_core_BalanceDelta,
        v4_core_BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, v4_core_BalanceDelta) {
        revert();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        v4_core_ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        v4_core_ModifyLiquidityParams calldata,
        v4_core_BalanceDelta,
        v4_core_BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, v4_core_BalanceDelta) {
        revert();
    }

    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        v4_core_BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, int128) {
        revert();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert();
    }
}

import {
    ModifyLiquidityParams as v4_core_ModifyLiquidityParams
} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta as v4_core_BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
