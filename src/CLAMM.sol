// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Tick} from "@v3-core/contracts/libraries/Tick.sol";
import {TickMath} from "@v3-core/contracts/libraries/TickMath.sol";
import {Position} from "@v3-core/contracts/libraries/Position.sol";
import {SafeCast} from "@v3-core/contracts/libraries/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

function checkTicks(int24 tickLower, int24 tickUpper) pure {
    require(tickLower < tickUpper, "tickLower >= tickUpper");
    require(tickLower >= TickMath.MIN_TICK, "tickLower < MIN_TICK");
    require(tickUpper <= TickMath.MAX_TICK);
}

contract CLAMM {
    using SafeCast for int256;
    using Position for mapping(bytes32 => Position.Info);
    using Tick for mapping(int24 => Tick.Info);
    using Position for Position.Info;

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint128 public immutable maxLiquidityPerTick;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        bool unlocked;
    }

    struct ModifyPositionParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    Slot0 public slot0;
    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    modifier lock() {
        require(slot0.unlocked, "Locked");
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    function initialize(uint160 sqrtPricex96) external {
        require(slot0.sqrtPriceX96 == 0, "Already initialized");
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPricex96);
        slot0 = Slot0({sqrtPriceX96: sqrtPricex96, tick: tick, unlocked: true});
    }

    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        private
        returns (Position.Info storage position)
    {
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = 0;
        uint256 _feeGrowthGlobal1X128 = 0;

        bool flippedLower;
        bool flippedUpper;

        if (liquidityDelta != 0) {
            //TODO: Have to remove these zeroes.
            flippedLower = ticks.update(tickLower, tick, liquidityDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128,0,0,0, false,maxLiquidityPerTick);
            flippedUpper = ticks.update(tickUpper, tick, liquidityDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128,0,0,0, true,maxLiquidityPerTick);

        }
        position.update(liquidityDelta, 0, 0);

        if (liquidityDelta < 0) {
            if(flippedLower) {
                ticks.clear(tickLower);
            }
            if(flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    function _modifyPosition(ModifyPositionParams memory params)
        private
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0;

        position = _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, _slot0.tick);

        return (positions[bytes32(0)], 0, 0);
    }

    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        require(amount > 0, "amount = 0");
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(amount)).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        if (amount0 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }

        if (amount1 > 0) {
            IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        }
    }
}
