// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WritVault} from "../src/WritVault.sol";
import {WritFactory} from "../src/WritFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// Fork tests against Robinhood Chain mainnet (chain 4663): real USDG, real stock tokens, real Uniswap v3 pools,
/// real SwapRouter02. Skipped unless run with a 4663 fork:
///   ALL_PROXY=socks5h://127.0.0.1:1080 forge test --fork-url https://rpc.mainnet.chain.robinhood.com --match-contract Fork -vv
///   or, without the tunnel: forge test --fork-url robinhood_fork --match-contract Fork -vv (drpc, archive)
/// (publicnode keeps only ~100 blocks of state, too short for a fork session; the official RPC is archive.)
contract WritVaultForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02
    address constant QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7; // QuoterV2
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address constant SLV = 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f;
    address constant USO = 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344;
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    /// Runtime codehash of the official stock-token BeaconProxy (read from NVDA, TSLA, SPY on 2026-10-20).
    bytes32 constant STOCK_CODEHASH = 0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630;

    uint256 constant USD = 1e6;

    WritFactory wf;
    WritVault vault;
    address writer = makeAddr("writer");
    address agent = makeAddr("agent");
    string constant WHY = "fork test";

    function setUp() public {
        if (block.chainid != 4663) vm.skip(true);
        address[] memory allow = new address[](4);
        allow[0] = NVDA;
        allow[1] = TSLA;
        allow[2] = AAPL;
        allow[3] = SPCX;
        uint24[] memory fees = new uint24[](4);
        (fees[0], fees[1], fees[2], fees[3]) = (500, 3000, 500, 500); // the stocks.json pools
        // $15 / trade, $60 / day, always on, 0.8 % max slippage vs 5-min TWAP
        wf = new WritFactory(ROUTER, FACTORY, USDG, STOCK_CODEHASH);
        vm.prank(writer);
        vault = WritVault(wf.open(agent, WritVault.Writ(15 * USD, 60 * USD, 0, 24, 0, 80, false), allow, fees));
        assertEq(vault.owner(), writer);
        deal(USDG, address(vault), 100 * USD);
        assertEq(IERC20(USDG).balanceOf(address(vault)), 100 * USD, "deal USDG");
    }

    function _fee(address stock) internal pure returns (uint24) {
        if (stock == GME) return 10000;
        if (stock == NVDA || stock == AAPL || stock == SPCX || stock == SPY || stock == GOOGL || stock == QQQ) return 500;
        return 3000;
    }

    function _quote(address tin, address tout, uint256 amt) internal returns (uint256 out) {
        (out,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams(tin, tout, amt, _fee(tin == USDG ? tout : tin), 0)
        );
    }

    /// What an agent does: quote, shave its own tolerance (0.3 %), never go under the vault's TWAP floor.
    function _minOut(address tin, address tout, uint256 amt) internal returns (uint256) {
        uint256 q = _quote(tin, tout, amt) * 9970 / 10000;
        (, uint256 floor_,,) = vault.quoteTwap(tin, tout, amt);
        return q > floor_ ? q : floor_;
    }

    function _exec(address tin, address tout, uint256 amt) internal returns (uint8 code, uint256 out) {
        uint256 minOut = _minOut(tin, tout, amt);
        vm.prank(agent);
        (code, out) = vault.execute(tin, tout, amt, minOut, _fee(tin == USDG ? tout : tin), WHY);
    }

    function test_fork_roundTrip_USDG_NVDA_USDG() public {
        uint256 g0 = gasleft();
        (uint8 code, uint256 nv) = _exec(USDG, NVDA, 10 * USD);
        uint256 gasBuy = g0 - gasleft();
        assertEq(code, 0, "buy refused");
        assertEq(IERC20(NVDA).balanceOf(address(vault)), nv);
        console2.log("BUY  10 USDG -> NVDA (wei):", nv);
        console2.log("     implied NVDA price (USDG * 1e6):", 10 * USD * 1e18 / nv);
        console2.log("     gas (incl. test quoting):", gasBuy);

        g0 = gasleft();
        (code, nv) = _exec(NVDA, USDG, nv);
        console2.log("SELL NVDA -> USDG (6 dec):", nv);
        console2.log("     gas (incl. test quoting):", g0 - gasleft());
        assertEq(code, 0, "sell refused");
        assertEq(IERC20(NVDA).balanceOf(address(vault)), 0);
        assertApproxEqRel(IERC20(USDG).balanceOf(address(vault)), 100 * USD, 0.01e18);
        assertEq(vault.spentToday(), 10 * USD + nv);
        assertEq(vault.seq(), 2);
        console2.log("spentToday:", vault.spentToday());
    }

    function test_fork_executeGas() public {
        uint256 minOut = _minOut(USDG, NVDA, 10 * USD);
        vm.prank(agent);
        uint256 g0 = gasleft();
        vault.execute(USDG, NVDA, 10 * USD, minOut, 500, WHY);
        console2.log("execute buy gas:", g0 - gasleft());
        uint256 nv = IERC20(NVDA).balanceOf(address(vault));
        minOut = _minOut(NVDA, USDG, nv);
        vm.prank(agent);
        g0 = gasleft();
        vault.execute(NVDA, USDG, nv, minOut, 500, WHY);
        console2.log("execute sell gas:", g0 - gasleft());
        vm.prank(agent);
        g0 = gasleft();
        vault.execute(USDG, SPY, 10 * USD, 1, 500, WHY);
        console2.log("execute refusal gas (code 4):", g0 - gasleft());
    }

    function test_fork_allRefusalCodes() public {
        uint8 code;
        // 4 not allowed (SPY is not on the writ)
        (code,) = _exec(USDG, SPY, 5 * USD);
        assertEq(code, 4);
        // 5 per-trade cap
        vm.prank(agent);
        (code,) = vault.execute(USDG, NVDA, 16 * USD, 1, 500, WHY);
        assertEq(code, 5);
        // 7: the real (thin) NVDA/USDG 0.3 % and 1 % pools exist, but only the pinned 0.05 % pool may be used
        vm.prank(agent);
        (code,) = vault.execute(USDG, NVDA, 5 * USD, 1, 3000, WHY);
        assertEq(code, 7);
        vm.prank(agent);
        (code,) = vault.execute(USDG, NVDA, 5 * USD, 1, 10000, WHY);
        assertEq(code, 7);
        // 7: stock -> stock
        vm.prank(agent);
        (code,) = vault.execute(USDG, USDG, 5 * USD, 1, 500, WHY);
        assertEq(code, 7);
        // 8a minOut under the TWAP floor (a dump at a bad price)
        (, uint256 floor_,,) = vault.quoteTwap(USDG, NVDA, 5 * USD);
        vm.prank(agent);
        (code,) = vault.execute(USDG, NVDA, 5 * USD, floor_ - 1, 500, WHY);
        assertEq(code, 8);
        // 8b minOut above what the pool gives → SwapRouter02 reverts "Too little received" → refused
        uint256 q = _quote(USDG, NVDA, 5 * USD);
        vm.prank(agent);
        (code,) = vault.execute(USDG, NVDA, 5 * USD, q * 101 / 100, 500, WHY);
        assertEq(code, 8);
        assertEq(IERC20(USDG).balanceOf(address(vault)), 100 * USD, "refusals moved funds");
        // 6 day cap: 4 × $15 then $1 more
        for (uint256 i; i < 4; ++i) {
            (code,) = _exec(USDG, NVDA, 15 * USD);
            assertEq(code, 0);
        }
        (code,) = _exec(USDG, NVDA, 1 * USD);
        assertEq(code, 6);
        // 6 for a sell: realised USDG out decided after the (rolled-back) swap
        uint256 nv = IERC20(NVDA).balanceOf(address(vault)) / 5;
        (code,) = _exec(NVDA, USDG, nv);
        assertEq(code, 6);
        // 5 for a sell: ~$60 of NVDA in one go
        vm.warp(block.timestamp + 1 days);
        nv = IERC20(NVDA).balanceOf(address(vault));
        (code,) = _exec(NVDA, USDG, nv);
        assertEq(code, 5);
        assertEq(IERC20(NVDA).balanceOf(address(vault)), nv, "sell refusal moved NVDA");
        // new day → fresh budget: a $15 sell settles
        (code,) = _exec(NVDA, USDG, nv / 4);
        assertEq(code, 0);
        // 1 quashed
        vm.prank(writer);
        vault.quash();
        (code,) = _exec(USDG, NVDA, 5 * USD);
        assertEq(code, 1);
        // 3 off hours
        uint256 h = (block.timestamp % 1 days) / 1 hours;
        vm.prank(writer);
        vault.setWrit(WritVault.Writ(15 * USD, 60 * USD, uint8((h + 1) % 24), uint8((h + 2) % 24 == 0 ? 24 : (h + 2) % 24), 0, 80, false));
        (code,) = _exec(USDG, NVDA, 5 * USD);
        assertEq(code, 3);
        // 2 expired
        vm.prank(writer);
        vault.setWrit(WritVault.Writ(15 * USD, 60 * USD, 0, 24, uint64(block.timestamp), 80, false));
        (code,) = _exec(USDG, NVDA, 5 * USD);
        assertEq(code, 2);
        console2.log("seq after all codes:", vault.seq());
    }

    function test_fork_replaceAllowList() public {
        address[] memory next = new address[](1);
        next[0] = SPY;
        vm.prank(writer);
        vault.replaceAllowList(next);
        (uint8 code,) = _exec(USDG, NVDA, 5 * USD);
        assertEq(code, 4);
        uint256 out;
        (code, out) = _exec(USDG, SPY, 10 * USD);
        assertEq(code, 0);
        assertEq(IERC20(SPY).balanceOf(address(vault)), out);
        console2.log("bought SPY (wei):", out);
    }

    /// Every stock in the default list is a real stock token (codehash) and its pinned USDG pool exists.
    function test_fork_defaultStocksAllowed() public {
        address[10] memory s = [NVDA, TSLA, AAPL, SPY, AMZN, GOOGL, QQQ, MSFT, SPCX, GLD];
        uint24[10] memory f = [uint24(500), 3000, 500, 500, 3000, 500, 500, 3000, 500, 3000];
        address[] memory allow = new address[](10);
        uint24[] memory fees = new uint24[](10);
        for (uint256 i; i < 10; ++i) {
            assertEq(s[i].codehash, STOCK_CODEHASH, "codehash");
            (allow[i], fees[i]) = (s[i], f[i]);
        }
        vm.prank(writer);
        WritVault v = WritVault(wf.open(agent, WritVault.Writ(15 * USD, 60 * USD, 0, 24, 0, 80, false), allow, fees));
        for (uint256 i; i < 10; ++i) {
            assertTrue(v.allowed(s[i]));
            (uint256 twap,,, uint32 w) = v.quoteTwap(USDG, s[i], 10 * USD);
            console2.log("stock", i, "twap out for 10 USDG (wei)", twap);
            console2.log("   window", w);
            assertGt(twap, 0);
        }
    }

    /// A fresh ERC20 named like a stock can never be allowed on the real chain.
    function test_fork_lookAlikeRejected() public {
        FakeStock fake = new FakeStock();
        address[] memory list = new address[](1);
        list[0] = address(fake);
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(WritVault.NotStockToken.selector, address(fake)));
        vault.setAllowed(list, true);
    }

    function test_fork_agentCannotWithdraw_writerCan() public {
        (, uint256 nv) = _exec(USDG, NVDA, 10 * USD);
        vm.startPrank(agent);
        vm.expectRevert();
        vault.withdraw(USDG, agent, 1);
        vm.expectRevert();
        vault.withdrawAll(agent);
        vm.expectRevert(WritVault.OnlySelf.selector);
        vault.selfSwap(USDG, NVDA, 500, 1 * USD, 1, false, 0);
        vm.stopPrank();
        assertEq(IERC20(USDG).balanceOf(agent), 0);

        vm.prank(writer);
        vault.withdrawAll(writer);
        assertEq(IERC20(USDG).balanceOf(writer), 90 * USD);
        assertEq(IERC20(NVDA).balanceOf(writer), nv);
        assertEq(IERC20(USDG).balanceOf(address(vault)), 0);
    }

    /// The vault's 5-minute TWAP price agrees with QuoterV2 on every pool in stocks.json (within fee + drift).
    function test_fork_twapMatchesQuoterOnAllPools() public {
        address[9] memory s = [SPY, GME, SLV, USO, GLD, TSLA, AAPL, NVDA, SPCX];
        vm.startPrank(writer);
        for (uint256 i; i < 9; ++i) {
            address[] memory one = new address[](1);
            one[0] = s[i];
            vault.setAllowed(one, true);
            vault.setPoolFee(s[i], _fee(s[i]));
        }
        vm.stopPrank();
        for (uint256 i; i < 9; ++i) {
            (uint256 twap,, uint24 fee, uint32 w) = vault.quoteTwap(USDG, s[i], 10 * USD);
            assertEq(fee, _fee(s[i]));
            uint256 q = _quote(USDG, s[i], 10 * USD);
            console2.log("pool", i, "twap window", w);
            console2.log("   twapOut / quoterOut (1e4 = equal)", twap * 1e4 / q);
            assertEq(w, 300);
            assertApproxEqRel(q, twap, 0.01e18); // TWAP net of LP fee vs QuoterV2
        }
    }
}

contract FakeStock is ERC20 {
    constructor() ERC20("NVIDIA", "NVDA") {}
}
