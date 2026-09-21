// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {WhaleTaxHook} from "../src/WhaleTaxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract WhaleTaxHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 1 << 96;
    uint24 constant BASE_FEE = 3_000;
    uint24 constant WHALE_FEE = 30_000;
    uint160 constant FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.BEFORE_SWAP;
    bytes32 constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    PoolManager manager;
    WhaleTaxHook hook;
    MockERC20 token0;
    MockERC20 token1;
    PoolModifyLiquidityTest liquidityRouter;
    PoolSwapTest swapRouter;
    PoolKey key;
    uint128 liquidity = 1_000_000 ether;

    function setUp() public {
        manager = new PoolManager(address(this));
        hook = _deployHook(IPoolManager(address(manager)), BASE_FEE, WHALE_FEE);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(this), type(uint128).max);
        token1.mint(address(this), type(uint128).max);

        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-120, 120, int256(uint256(liquidity)), bytes32(0)), ""
        );
    }

    function test_justUnderThresholdPaysBaseFee() public {
        uint256 cutoff = uint256(IPoolManager(address(manager)).getLiquidity(key.toId())) / 100;
        assertEq(hook.previewFee(key, -int256(cutoff - 1)), BASE_FEE);
        assertEq(_swapAndReadFee(-int256(cutoff - 1), true, hex"feed"), BASE_FEE);
    }

    function test_justOverThresholdPaysWhaleFee() public {
        uint256 cutoff = uint256(IPoolManager(address(manager)).getLiquidity(key.toId())) / 100;
        assertEq(hook.previewFee(key, -int256(cutoff + 1)), WHALE_FEE);
        assertEq(_swapAndReadFee(-int256(cutoff + 1), false, hex""), WHALE_FEE);
    }

    function test_exactlyAtThresholdPaysBaseFee() public view {
        uint256 cutoff = uint256(IPoolManager(address(manager)).getLiquidity(key.toId())) / 100;
        assertEq(hook.previewFee(key, int256(cutoff)), BASE_FEE);
        assertEq(hook.threshold(key), cutoff);
    }

    function test_rejectsStaticFeePool() public {
        PoolKey memory staticKey = key;
        staticKey.fee = BASE_FEE;
        vm.expectRevert();
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    function test_callbacksAuthenticateTheManager() public {
        vm.expectRevert(WhaleTaxHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), bytes("forged")
        );
        vm.expectRevert(WhaleTaxHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_liquidityCanBeRemovedInFull() public {
        _swapAndReadFee(-int256(uint256(liquidity) / 100 + 1), true, "");
        liquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(-120, 120, -int256(uint256(liquidity)), bytes32(0)), ""
        );
        (uint128 remaining,,) = IPoolManager(address(manager))
            .getPositionInfo(key.toId(), address(liquidityRouter), -120, 120, bytes32(0));
        assertEq(remaining, 0);
    }

    function _swapAndReadFee(int256 amount, bool zeroForOne, bytes memory hookData)
        internal
        returns (uint24 fee)
    {
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams(
                zeroForOne,
                amount,
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            hookData
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        assertTrue(false, "Swap event missing");
    }

    function _deployHook(IPoolManager manager_, uint24 baseFee_, uint24 whaleFee_)
        internal
        returns (WhaleTaxHook deployed)
    {
        bytes memory init = abi.encodePacked(
            type(WhaleTaxHook).creationCode, abi.encode(manager_, baseFee_, whaleFee_)
        );
        bytes32 hash = keccak256(init);
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted = vm.computeCreate2Address(bytes32(salt), hash, address(this));
            if (HookFlags.matches(predicted, FLAGS)) {
                return new WhaleTaxHook{salt: bytes32(salt)}(manager_, baseFee_, whaleFee_);
            }
        }
        revert("no hook salt");
    }
}
