// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WritVault} from "../src/WritVault.sol";
import {WritVault} from "../src/WritVault.sol";
import {MockERC20, MockPool, MockFactory, MockRouter} from "./mocks/Mocks.sol";

contract WritVaultTest is Test {
    event Filed(
        uint256 indexed seq,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 notional,
        uint256 spentToday,
        uint256 maxPerTrade,
        uint256 maxPerDay,
        string reason
    );
    event Refused(
        uint256 indexed seq, uint8 indexed code, address tokenIn, address tokenOut, uint256 amountIn, string reason
    );

    uint256 constant USD = 1e6;
    uint24 constant FEE = 500; // 0.05 %

    MockERC20 usdg;
    MockERC20 nvda;
    MockERC20 tsla;
    MockERC20 spy;
    MockFactory factory;
    MockRouter router;
    MockPool nvdaPool;
    MockPool tslaPool;
    MockPool spyPool;
    WritVault vault;

    address writer = makeAddr("writer");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");
    string constant WHY = "NVDA up 2.1% on the hour, volume rising.";

    function setUp() public {
        vm.warp(1_791_331_200 + 12 hours); // 2026-10-08 12:00 UTC
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVIDIA", "NVDA", 18);
        tsla = new MockERC20("Tesla", "TSLA", 18);
        spy = new MockERC20("SPY", "SPY", 18);
        factory = new MockFactory();
        router = new MockRouter(factory);
        nvdaPool = _pool(nvda, 200);
        tslaPool = _pool(tsla, 400);
        spyPool = _pool(spy, 650);

        address[] memory allow = new address[](2);
        allow[0] = address(nvda);
        allow[1] = address(tsla);
        vault = new WritVault(
            address(router), address(factory), address(usdg), address(nvda).codehash, writer, agent, _writ(15, 60, 0, 24, 0, 80), allow, new uint24[](0)
        );
        usdg.mint(address(vault), 100 * USD);
    }

    // ─── helpers ───

    /// pool for `stock` priced at ~`usd` per share (USDG 6 dec, stock 18 dec)
    function _pool(MockERC20 stock, uint256 usd) internal returns (MockPool p) {
        // raw stock per raw usdg = 1e12 / usd → tick = log_1.0001(1e12/usd)
        int24 t = _tickFor(1e12 / usd);
        int24 tick = address(usdg) < address(stock) ? t : -t;
        p = new MockPool(address(usdg), address(stock), FEE, tick);
        factory.setPool(address(usdg), address(stock), FEE, address(p));
    }

    function _tickFor(uint256 ratio) internal pure returns (int24 t) {
        // integer log base 1.0001 by bisection on 1.0001^t (good enough for a mock price)
        int256 lo = 0;
        int256 hi = 400_000;
        while (hi - lo > 1) {
            int256 mid = (lo + hi) / 2;
            if (_pow(mid) <= ratio) lo = mid;
            else hi = mid;
        }
        t = int24(lo);
    }

    function _pow(int256 t) internal pure returns (uint256 r) {
        // 1.0001^t via sqrtPrice: (sqrtP / 2^96)^2
        uint256 sp = uint256(uint160(_sqrt(int24(t))));
        r = (sp * sp) >> 192;
    }

    function _sqrt(int24 t) internal pure returns (uint160) {
        return TickMathHelper.at(t);
    }

    function _writ(uint256 trade, uint256 day, uint8 from, uint8 to, uint64 expiry, uint16 bps)
        internal
        pure
        returns (WritVault.Writ memory)
    {
        return WritVault.Writ(trade * USD, day * USD, from, to, expiry, bps, false);
    }

    function _floor(address tin, address tout, uint256 amt) internal view returns (uint256 f) {
        (, f,,) = vault.quoteTwap(tin, tout, amt);
    }

    function _buy(MockERC20 stock, uint256 usd) internal returns (uint8 code, uint256 out) {
        uint256 amt = usd * USD;
        uint256 minOut = _floor(address(usdg), address(stock), amt);
        vm.prank(agent);
        return vault.execute(address(usdg), address(stock), amt, minOut, FEE, WHY);
    }

    function _sell(MockERC20 stock, uint256 amt) internal returns (uint8 code, uint256 out) {
        uint256 minOut = _floor(address(stock), address(usdg), amt);
        vm.prank(agent);
        return vault.execute(address(stock), address(usdg), amt, minOut, FEE, WHY);
    }

    function _expectRefused(uint256 s, uint8 code, address tin, address tout, uint256 amt) internal {
        vm.expectEmit(true, true, false, true, address(vault));
        emit Refused(s, code, tin, tout, amt, WHY);
    }

    // ─── fills ───

    function test_buyFiled() public {
        uint256 amt = 10 * USD;
        uint256 minOut = _floor(address(usdg), address(nvda), amt);
        assertGt(minOut, 0.0495e18 * 0.99); // ~ $200 → 0.05 NVDA, floor = -0.8 %
        vm.expectEmit(true, true, true, false, address(vault));
        emit Filed(1, address(usdg), address(nvda), amt, 0, amt, amt, 15 * USD, 60 * USD, WHY);
        vm.prank(agent);
        (uint8 code, uint256 out) = vault.execute(address(usdg), address(nvda), amt, minOut, FEE, WHY);
        assertEq(code, 0);
        assertGe(out, minOut);
        assertEq(nvda.balanceOf(address(vault)), out);
        assertEq(usdg.balanceOf(address(vault)), 90 * USD);
        assertEq(vault.spentToday(), amt);
        assertEq(vault.seq(), 1);
        assertEq(usdg.allowance(address(vault), address(router)), 0);
    }

    function test_sellFiled_notionalIsUsdgOut() public {
        (, uint256 got) = _buy(nvda, 10);
        vm.recordLogs();
        (uint8 code, uint256 usdOut) = _sell(nvda, got);
        assertEq(code, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory k = logs[logs.length - 1];
        assertEq(k.topics[0], Filed.selector);
        assertEq(uint256(k.topics[1]), 2);
        (uint256 aIn, uint256 aOut, uint256 notional, uint256 spent,,, string memory why) =
            abi.decode(k.data, (uint256, uint256, uint256, uint256, uint256, uint256, string));
        assertEq(why, WHY);
        assertEq(aIn, got);
        assertEq(aOut, usdOut);
        assertEq(notional, usdOut);
        assertEq(spent, 10 * USD + usdOut);
        assertApproxEqRel(usdOut, 10 * USD, 0.002e18); // two 0.05 % fees
        assertEq(nvda.balanceOf(address(vault)), 0);
    }

    // ─── refusals, one per code ───

    function test_refuse1_quashed() public {
        vm.prank(writer);
        vault.quash();
        _expectRefused(1, 1, address(usdg), address(nvda), 10 * USD);
        (uint8 code,) = _buy(nvda, 10);
        assertEq(code, 1);
        assertEq(usdg.balanceOf(address(vault)), 100 * USD);
        vm.prank(writer);
        vault.unquash();
        (code,) = _buy(nvda, 10);
        assertEq(code, 0);
    }

    function test_refuse2_expired() public {
        vm.prank(writer);
        vault.setWrit(_writ(15, 60, 0, 24, uint64(block.timestamp + 1 hours), 80));
        (uint8 code,) = _buy(nvda, 5);
        assertEq(code, 0);
        vm.warp(block.timestamp + 1 hours);
        _expectRefused(2, 2, address(usdg), address(nvda), 5 * USD);
        (code,) = _buy(nvda, 5);
        assertEq(code, 2);
    }

    function test_refuse3_offHours() public {
        // 13:30–20:00 UTC (US cash session); now 12:00 → refused
        vm.prank(writer);
        vault.setWrit(_writ(15, 60, 13, 20, 0, 80));
        _expectRefused(1, 3, address(usdg), address(nvda), 5 * USD);
        (uint8 code,) = _buy(nvda, 5);
        assertEq(code, 3);
        vm.warp(block.timestamp + 1 hours); // 13:00
        (code,) = _buy(nvda, 5);
        assertEq(code, 0);
        vm.warp(block.timestamp + 7 hours); // 20:00 → closed (end exclusive)
        (code,) = _buy(nvda, 5);
        assertEq(code, 3);
    }

    function test_refuse3_wrapPastMidnight() public {
        vm.prank(writer);
        vault.setWrit(_writ(15, 60, 22, 2, 0, 80)); // 22:00–02:00
        (uint8 code,) = _buy(nvda, 1); // 12:00
        assertEq(code, 3);
        vm.warp(block.timestamp + 11 hours); // 23:00
        (code,) = _buy(nvda, 1);
        assertEq(code, 0);
        vm.warp(block.timestamp + 2 hours); // 01:00
        (code,) = _buy(nvda, 1);
        assertEq(code, 0);
        vm.warp(block.timestamp + 1 hours); // 02:00
        (code,) = _buy(nvda, 1);
        assertEq(code, 3);
    }

    function test_refuse4_notAllowed() public {
        spy.mint(address(vault), 1e18);
        _expectRefused(1, 4, address(usdg), address(spy), 5 * USD);
        (uint8 code,) = _buy(spy, 5);
        assertEq(code, 4);
        (code,) = _sell(spy, 0.01e18);
        assertEq(code, 4);
    }

    function test_refuse5_tradeCap_buy() public {
        _expectRefused(1, 5, address(usdg), address(nvda), 16 * USD);
        (uint8 code,) = _buy(nvda, 16);
        assertEq(code, 5);
        (code,) = _buy(nvda, 15); // exactly the cap is fine
        assertEq(code, 0);
    }

    function test_refuse5_tradeCap_sell_rolledBack() public {
        (, uint256 a) = _buy(nvda, 15);
        (, uint256 b) = _buy(nvda, 15);
        uint256 usdBefore = usdg.balanceOf(address(vault));
        // selling ~$30 of NVDA is over the $15 per-trade cap → decided after the swap, swap rolled back
        _expectRefused(3, 5, address(nvda), address(usdg), a + b);
        (uint8 code, uint256 out) = _sell(nvda, a + b);
        assertEq(code, 5);
        assertEq(out, 0);
        assertEq(nvda.balanceOf(address(vault)), a + b);
        assertEq(usdg.balanceOf(address(vault)), usdBefore);
        assertEq(nvda.allowance(address(vault), address(router)), 0);
        assertEq(vault.spentToday(), 30 * USD);
    }

    function test_refuse6_dayCap_buy_andDayBoundary() public {
        for (uint256 i; i < 4; ++i) {
            (uint8 c,) = _buy(nvda, 15);
            assertEq(c, 0);
        }
        assertEq(vault.spentToday(), 60 * USD);
        _expectRefused(5, 6, address(usdg), address(nvda), 1 * USD);
        (uint8 code,) = _buy(nvda, 1);
        assertEq(code, 6);
        // next UTC day: fresh budget
        uint256 d = vault.today();
        vm.warp((d + 1) * 1 days);
        assertEq(vault.spentToday(), 0);
        assertEq(vault.spentOn(d), 60 * USD);
        (code,) = _buy(nvda, 15);
        assertEq(code, 0);
        assertEq(vault.spentOn(d + 1), 15 * USD);
    }

    function test_refuse6_dayCap_sell() public {
        (, uint256 a) = _buy(nvda, 15);
        _buy(nvda, 15);
        _buy(nvda, 15);
        _buy(nvda, 14); // spent 59
        (uint8 code,) = _sell(nvda, a); // ~$15 out → 74 > 60
        assertEq(code, 6);
        assertEq(vault.spentToday(), 59 * USD);
    }

    function test_refuse7_notQuotePair() public {
        tsla.mint(address(vault), 1e18);
        // stock → stock (both allowed)
        _expectRefused(1, 7, address(tsla), address(nvda), 0.01e18);
        vm.prank(agent);
        (uint8 code,) = vault.execute(address(tsla), address(nvda), 0.01e18, 1, FEE, WHY);
        assertEq(code, 7);
        // USDG → USDG
        vm.prank(agent);
        (code,) = vault.execute(address(usdg), address(usdg), USD, USD, FEE, WHY);
        assertEq(code, 7);
        // right pair, but not the pinned fee tier — even though a (thin) 1 % pool exists
        MockPool thin = new MockPool(address(usdg), address(nvda), 10000, nvdaPool.twapTick());
        factory.setPool(address(usdg), address(nvda), 10000, address(thin));
        vm.prank(agent);
        (code,) = vault.execute(address(usdg), address(nvda), USD, 1, 10000, WHY);
        assertEq(code, 7);
        vm.prank(agent);
        (code,) = vault.execute(address(usdg), address(nvda), USD, 1, 3000, WHY);
        assertEq(code, 7);
    }

    function test_poolPinning() public {
        assertEq(vault.pinnedPool(address(nvda)), address(nvdaPool));
        assertEq(vault.poolFee(address(nvda)), FEE);
        // a deeper 0.3 % SPY pool exists → auto-pick takes it when SPY is first allowed
        MockPool deep = new MockPool(address(usdg), address(spy), 3000, spyPool.twapTick());
        deep.setLiquidity(5e18);
        factory.setPool(address(usdg), address(spy), 3000, address(deep));
        address[] memory list = new address[](1);
        list[0] = address(spy);
        vm.prank(writer);
        vault.setAllowed(list, true);
        assertEq(vault.poolFee(address(spy)), 3000);
        (,, uint24 fee,) = vault.quoteTwap(address(usdg), address(spy), USD);
        assertEq(fee, 3000);
        // writer re-pins explicitly
        vm.startPrank(writer);
        vault.setPoolFee(address(spy), FEE);
        assertEq(vault.pinnedPool(address(spy)), address(spyPool));
        vm.expectRevert(abi.encodeWithSelector(WritVault.NoPool.selector, address(spy), uint24(100)));
        vault.setPoolFee(address(spy), 100);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.setPoolFee(address(spy), 3000);
        // constructor pins explicit fees
        address[] memory allow = new address[](1);
        allow[0] = address(spy);
        uint24[] memory fees = new uint24[](1);
        fees[0] = FEE;
        WritVault v2 = new WritVault(
            address(router), address(factory), address(usdg), address(nvda).codehash, writer, agent, _writ(15, 60, 0, 24, 0, 80), allow, fees
        );
        assertEq(v2.pinnedPool(address(spy)), address(spyPool));
        // a stock with no USDG pool at all cannot be allowed
        MockERC20 orphan = new MockERC20("X", "X", 18);
        list[0] = address(orphan);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(WritVault.NoPool.selector, address(orphan), uint24(0)));
        vault.setAllowed(list, true);
    }

    function test_refuse8_minOutBelowTwapFloor() public {
        uint256 amt = 10 * USD;
        uint256 floor_ = _floor(address(usdg), address(nvda), amt);
        _expectRefused(1, 8, address(usdg), address(nvda), amt);
        vm.prank(agent);
        (uint8 code,) = vault.execute(address(usdg), address(nvda), amt, floor_ - 1, FEE, WHY);
        assertEq(code, 8);
        vm.prank(agent);
        (code,) = vault.execute(address(usdg), address(nvda), amt, 0, FEE, WHY);
        assertEq(code, 8);
        assertEq(usdg.balanceOf(address(vault)), 100 * USD);
    }

    /// A compromised key that dumps into a manipulated spot price still gets refused: the floor comes from the TWAP.
    function test_refuse8_spotManipulated_routerReverts() public {
        (, uint256 got) = _buy(nvda, 10);
        // attacker crashes the NVDA spot price 20 % (spot tick moves; TWAP barely moves)
        int24 twap = nvdaPool.twapTick();
        int24 crashed = address(usdg) < address(nvda) ? twap + 2231 : twap - 2231; // more stock per USDG = cheaper NVDA
        nvdaPool.setTicks(twap, crashed);
        uint256 floor_ = _floor(address(nvda), address(usdg), got);
        vm.prank(agent);
        (uint8 code,) = vault.execute(address(nvda), address(usdg), got, floor_, FEE, WHY);
        assertEq(code, 8); // router: "Too little received"
        assertEq(nvda.balanceOf(address(vault)), got);
    }

    /// Venue failures that are not slippage are not refusals: the execute reverts and nothing is recorded.
    function test_nonSlippageRouterRevert_bubbles() public {
        router.setForceRevert(true);
        uint256 amt = 5 * USD;
        uint256 minOut = _floor(address(usdg), address(nvda), amt);
        vm.prank(agent);
        vm.expectRevert(bytes("forced"));
        vault.execute(address(usdg), address(nvda), amt, minOut, FEE, WHY);
        assertEq(vault.seq(), 0);
        assertEq(vault.spentToday(), 0);
    }

    /// eth_estimateGas regression: an out-of-gas swap leg must revert the execute, never turn into a refusal.
    function test_outOfGasSwapRevertsNotRefuses() public {
        router.setBurnLoops(2000);
        uint256 amt = 5 * USD;
        uint256 minOut = _floor(address(usdg), address(nvda), amt);
        vm.prank(agent);
        vm.expectRevert(WritVault.SwapOutOfGas.selector);
        vault.execute{gas: 300_000}(address(usdg), address(nvda), amt, minOut, FEE, WHY);
        assertEq(vault.seq(), 0);
        // with enough gas it settles
        vm.prank(agent);
        (uint8 code,) = vault.execute{gas: 5_000_000}(address(usdg), address(nvda), amt, minOut, FEE, WHY);
        assertEq(code, 0);
        // a router revert without data also reverts (not a refusal)
        router.setEmptyRevert(true);
        vm.prank(agent);
        vm.expectRevert(WritVault.SwapOutOfGas.selector);
        vault.execute(address(usdg), address(nvda), amt, minOut, FEE, WHY);
    }

    function test_refusalOrder() public {
        vm.startPrank(writer);
        vault.setWrit(WritVault.Writ(15 * USD, 60 * USD, 13, 20, uint64(block.timestamp - 1), 80, true));
        vm.stopPrank();
        // quashed + expired + off-hours + not allowed + over cap → 1
        (uint8 code,) = _buy(spy, 99);
        assertEq(code, 1);
        vm.prank(writer);
        vault.unquash();
        (code,) = _buy(spy, 99);
        assertEq(code, 2);
        vm.prank(writer);
        vault.setWrit(_writ(15, 60, 13, 20, 0, 80));
        (code,) = _buy(spy, 99);
        assertEq(code, 3);
        vm.prank(writer);
        vault.setWrit(_writ(15, 60, 0, 24, 0, 80));
        (code,) = _buy(spy, 99);
        assertEq(code, 4);
        (code,) = _buy(nvda, 99);
        assertEq(code, 5);
        assertEq(vault.seq(), 5);
    }

    function test_seqCountsFilesAndRefusals() public {
        _buy(nvda, 5);
        _buy(nvda, 50);
        _buy(spy, 5);
        _buy(nvda, 5);
        assertEq(vault.seq(), 4);
    }

    // ─── malformed calls revert (not writ breaches) ───

    function test_revert_zeroOrInsufficient() public {
        vm.startPrank(agent);
        vm.expectRevert(WritVault.ZeroAmount.selector);
        vault.execute(address(usdg), address(nvda), 0, 1, FEE, WHY);
        vm.expectRevert(
            abi.encodeWithSelector(WritVault.InsufficientBalance.selector, address(usdg), 100 * USD, 101 * USD)
        );
        vault.execute(address(usdg), address(nvda), 101 * USD, 1, FEE, WHY);
        vm.stopPrank();
        assertEq(vault.seq(), 0);
    }

    // ─── access control: the agent can only execute ───

    function test_onlyAgentCanExecute() public {
        vm.prank(writer);
        vm.expectRevert(WritVault.NotAgent.selector);
        vault.execute(address(usdg), address(nvda), USD, 1, FEE, WHY);
        vm.prank(stranger);
        vm.expectRevert(WritVault.NotAgent.selector);
        vault.execute(address(usdg), address(nvda), USD, 1, FEE, WHY);
    }

    function test_agentCannotMoveFundsOrChangeWrit() public {
        address[] memory list = new address[](1);
        list[0] = address(spy);
        vm.startPrank(agent);
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent);
        vm.expectRevert(notOwner);
        vault.withdraw(address(usdg), agent, 1);
        vm.expectRevert(notOwner);
        vault.withdrawAll(agent);
        vm.expectRevert(notOwner);
        vault.setWrit(_writ(1000, 1000, 0, 24, 0, 1000));
        vm.expectRevert(notOwner);
        vault.setAllowed(list, true);
        vm.expectRevert(notOwner);
        vault.replaceAllowList(list);
        vm.expectRevert(notOwner);
        vault.unquash();
        vm.expectRevert(notOwner);
        vault.quash();
        vm.expectRevert(notOwner);
        vault.setAgent(stranger);
        vm.expectRevert(notOwner);
        vault.transferOwnership(agent);
        vm.expectRevert(WritVault.OnlySelf.selector);
        vault.selfSwap(address(usdg), address(nvda), FEE, USD, 1, false, 0);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(vault)), 100 * USD);
    }

    function test_swapOutputLandsInVaultOnly() public {
        uint256 agentBefore = nvda.balanceOf(agent);
        (, uint256 out) = _buy(nvda, 10);
        assertEq(nvda.balanceOf(agent), agentBefore);
        assertEq(nvda.balanceOf(address(vault)), out);
    }

    // ─── writer ───

    function test_writerWithdraw() public {
        vm.prank(writer);
        vault.withdraw(address(usdg), writer, 40 * USD);
        assertEq(usdg.balanceOf(writer), 40 * USD);
    }

    function test_withdrawAllSweepsDelistedStocks() public {
        (, uint256 got) = _buy(nvda, 10);
        address[] memory list = new address[](1);
        list[0] = address(spy);
        vm.prank(writer);
        vault.replaceAllowList(list); // NVDA leaves the allowlist but is still held
        assertFalse(vault.allowed(address(nvda)));
        vm.prank(writer);
        vault.withdrawAll(writer);
        assertEq(usdg.balanceOf(writer), 90 * USD);
        assertEq(nvda.balanceOf(writer), got);
        assertEq(vault.seenTokens().length, 3);
    }

    function test_ownerReplacesAllowList() public {
        address[] memory list = new address[](1);
        list[0] = address(spy);
        vm.prank(writer);
        vault.replaceAllowList(list);
        address[] memory now_ = vault.allowList();
        assertEq(now_.length, 1);
        assertEq(now_[0], address(spy));
        (uint8 code,) = _buy(nvda, 5);
        assertEq(code, 4);
        (code,) = _buy(spy, 5);
        assertEq(code, 0);
    }

    /// After the allowlist rolls, yesterday's stock can still be sold (never bought); never-allowed stocks cannot.
    function test_sellDelistedStock_buyRefused() public {
        (, uint256 got) = _buy(nvda, 10);
        assertTrue(vault.everAllowed(address(nvda)));
        assertFalse(vault.everAllowed(address(spy)));
        address[] memory list = new address[](1);
        list[0] = address(spy);
        vm.prank(writer);
        vault.replaceAllowList(list);
        assertFalse(vault.allowed(address(nvda)));
        assertTrue(vault.everAllowed(address(nvda)));
        (uint8 code,) = _buy(nvda, 5);
        assertEq(code, 4);
        (code,) = _sell(nvda, got / 2);
        assertEq(code, 0);
        // explicit removal by the writer: still sellable
        list[0] = address(nvda);
        vm.prank(writer);
        vault.setAllowed(list, false);
        (code,) = _sell(nvda, got - got / 2);
        assertEq(code, 0);
        assertEq(nvda.balanceOf(address(vault)), 0);
        // other gates still apply to the delisted sell: quash, caps, wrong fee tier
        (, uint256 g2) = _buy(spy, 10);
        list[0] = address(tsla);
        vm.prank(writer);
        vault.replaceAllowList(list);
        vm.prank(agent);
        (code,) = vault.execute(address(spy), address(usdg), g2, 1, 3000, WHY);
        assertEq(code, 7);
        vm.prank(writer);
        vault.quash();
        (code,) = _sell(spy, g2);
        assertEq(code, 1);
    }

    function test_setAllowedAndBadTokens() public {
        address[] memory list = new address[](1);
        list[0] = address(usdg);
        vm.startPrank(writer);
        vm.expectRevert(abi.encodeWithSelector(WritVault.BadToken.selector, address(usdg)));
        vault.setAllowed(list, true);
        list[0] = address(nvda);
        vault.setAllowed(list, false);
        vm.stopPrank();
        assertFalse(vault.allowed(address(nvda)));
        assertEq(vault.allowList().length, 1);
    }

    function test_setWritValidation() public {
        vm.startPrank(writer);
        vm.expectRevert(WritVault.BadWrit.selector);
        vault.setWrit(_writ(15, 60, 24, 24, 0, 80));
        vm.expectRevert(WritVault.BadWrit.selector);
        vault.setWrit(_writ(15, 60, 5, 5, 0, 80));
        vm.expectRevert(WritVault.BadWrit.selector);
        vault.setWrit(_writ(15, 60, 0, 25, 0, 80));
        vm.expectRevert(WritVault.BadWrit.selector);
        vault.setWrit(_writ(15, 60, 0, 24, 0, 1001));
        vm.expectRevert(WritVault.BadWrit.selector);
        vault.setWrit(_writ(0, 60, 0, 24, 0, 80));
        vm.expectRevert(WritVault.BadWrit.selector);
        vault.setWrit(_writ(61, 60, 0, 24, 0, 80));
        vault.setWrit(_writ(20, 80, 22, 0, 0, 120));
        vm.stopPrank();
        WritVault.Writ memory j = vault.writ();
        assertEq(j.maxPerTrade, 20 * USD);
        assertEq(j.activeFrom, 22);
        assertEq(j.activeTo, 0);
        assertEq(j.maxSlippageBps, 120);
    }

    function test_rolesAndOwnership() public {
        vm.startPrank(writer);
        vm.expectRevert(WritVault.RoleClash.selector);
        vault.setAgent(writer);
        vm.expectRevert(WritVault.RoleClash.selector);
        vault.transferOwnership(agent);
        vm.expectRevert(WritVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        // new agent key
        address agent2 = makeAddr("agent2");
        vault.setAgent(agent2);
        // two-step transfer
        vault.transferOwnership(stranger);
        vm.stopPrank();
        assertEq(vault.owner(), writer);
        vm.prank(stranger);
        vault.acceptOwnership();
        assertEq(vault.owner(), stranger);
        vm.prank(agent);
        vm.expectRevert(WritVault.NotAgent.selector);
        vault.execute(address(usdg), address(nvda), USD, 1, FEE, WHY);
    }

    function test_constructorGuards() public {
        address[] memory allow = new address[](0);
        WritVault.Writ memory j = _writ(15, 60, 0, 24, 0, 80);
        bytes32 H = address(nvda).codehash;
        vm.expectRevert(WritVault.ZeroAddress.selector);
        new WritVault(address(router), address(factory), address(usdg), H, writer, address(0), j, allow, new uint24[](0));
        vm.expectRevert(WritVault.RoleClash.selector);
        new WritVault(address(router), address(factory), address(usdg), H, writer, writer, j, allow, new uint24[](0));
        vm.expectRevert(WritVault.ZeroAddress.selector);
        new WritVault(address(0), address(factory), address(usdg), H, writer, agent, j, allow, new uint24[](0));
    }

    // ─── TWAP oracle ───

    function test_twapWindowShrinksToOldestObservation() public {
        nvdaPool.setOracle(1, 60);
        (,,, uint32 w) = vault.quoteTwap(address(usdg), address(nvda), USD);
        assertEq(w, 60);
        nvdaPool.setOracle(1, 0); // single observation written this block → spot (slot0)
        (uint256 e,,, uint32 w2) = vault.quoteTwap(address(usdg), address(nvda), USD);
        assertEq(w2, 0);
        assertGt(e, 0);
        nvdaPool.setOracle(100, 3600);
        (,,, uint32 w3) = vault.quoteTwap(address(usdg), address(nvda), USD);
        assertEq(w3, 300);
    }

    function test_isActive() public {
        assertTrue(vault.isActive());
        vm.prank(writer);
        vault.quash();
        assertFalse(vault.isActive());
    }

    // ─── Writbound additions ───

    /// A look-alike token (same name, symbol and decimals, different contract) can never be allowed.
    function test_lookAlikeStockRejected() public {
        LookAlike fake = new LookAlike();
        MockPool p = new MockPool(address(usdg), address(fake), FEE, nvdaPool.twapTick());
        factory.setPool(address(usdg), address(fake), FEE, address(p));
        address[] memory list = new address[](1);
        list[0] = address(fake);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(WritVault.NotStockToken.selector, address(fake)));
        vault.setAllowed(list, true);
        uint24[] memory fees = new uint24[](1);
        fees[0] = FEE;
        vm.expectRevert(abi.encodeWithSelector(WritVault.NotStockToken.selector, address(fake)));
        new WritVault(
            address(router), address(factory), address(usdg), address(nvda).codehash, writer, agent, _writ(15, 60, 0, 24, 0, 80), list, fees
        );
        assertEq(vault.stockCodehash(), address(nvda).codehash);
    }

    function test_reasonPublishedAndCapped() public {
        string memory r280 = _repeat("x", 280);
        uint256 amt = 5 * USD;
        uint256 minOut = _floor(address(usdg), address(nvda), amt);
        vm.prank(agent);
        (uint8 code,) = vault.execute(address(usdg), address(nvda), amt, minOut, FEE, r280);
        assertEq(code, 0);
        string memory r281 = _repeat("x", 281);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(WritVault.ReasonTooLong.selector, 281));
        vault.execute(address(usdg), address(nvda), amt, minOut, FEE, r281);
        // a refusal carries the agent's words too
        string memory why = "Owner asked for 20 USDG of NVDA; the writ caps a trade at 15.";
        vm.expectEmit(true, true, false, true, address(vault));
        emit Refused(2, 5, address(usdg), address(nvda), 20 * USD, why);
        vm.prank(agent);
        vault.execute(address(usdg), address(nvda), 20 * USD, 1, FEE, why);
        assertEq(vault.seq(), 2);
    }

    function test_leftToday() public {
        assertEq(vault.leftToday(), 60 * USD);
        _buy(nvda, 15);
        assertEq(vault.leftToday(), 45 * USD);
        _buy(nvda, 15);
        _buy(nvda, 15);
        _buy(nvda, 15);
        assertEq(vault.leftToday(), 0);
        vm.prank(writer);
        vault.setWrit(_writ(15, 30, 0, 24, 0, 80)); // cap lowered below what was spent
        assertEq(vault.leftToday(), 0);
    }

    function test_writFactoryIsDeployer() public view {
        assertEq(vault.writFactory(), address(this));
        assertEq(vault.owner(), writer);
        assertEq(vault.agent(), agent);
    }

    function _repeat(string memory c, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes(c)[0];
        }
        return string(b);
    }

    // ─── fuzz: the day cap can never be exceeded, whatever the agent sends ───

    function testFuzz_dayCapHolds(uint256[8] calldata amts, bool[8] calldata sells) public {
        for (uint256 i; i < 8; ++i) {
            uint256 bal;
            if (sells[i]) {
                bal = nvda.balanceOf(address(vault));
                if (bal == 0) continue;
                _sell(nvda, bound(amts[i], 1, bal));
            } else {
                bal = usdg.balanceOf(address(vault));
                if (bal == 0) continue;
                _buy_raw(bound(amts[i], 1, bal));
            }
            assertLe(vault.spentToday(), 60 * USD);
        }
        assertEq(vault.seq() <= 8, true);
    }

    function _buy_raw(uint256 amt) internal {
        uint256 minOut = _floor(address(usdg), address(nvda), amt);
        if (minOut == 0) minOut = 1;
        vm.prank(agent);
        vault.execute(address(usdg), address(nvda), amt, minOut, FEE, WHY);
    }
}

import {TickMath} from "../src/libraries/uniswap/TickMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Same name/symbol/decimals as a real stock token, different bytecode.
contract LookAlike is ERC20 {
    constructor() ERC20("NVIDIA", "NVDA") {
        _mint(msg.sender, 1e24);
    }
}

library TickMathHelper {
    function at(int24 t) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(t);
    }
}
