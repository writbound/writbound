// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IUniswapV3Factory, IUniswapV3PoolLike, ISwapRouter02} from "./interfaces/IUniswapV3.sol";
import {TwapOracle} from "./libraries/TwapOracle.sol";

/// @title  WritVault — one owner's vault, traded by one AI agent, bound by the owner's writ.
/// @notice The agent's key can do exactly one thing: `execute` (a tokenized stock <-> USDG through one pinned Uniswap v3
///         pool on Robinhood Chain), and only inside the writ. A writ breach never reverts: it emits `Refused(code)` and
///         returns, so every refusal is on-chain. A settled trade emits `Filed`. Funds arrive by plain transfer; only the
///         owner can take them out. The trade engine is TiercelVault (project 160), unchanged where it could be.
///
///         Refusal codes, checked in this order:
///           1 QUASHED · 2 EXPIRED · 3 OFF_HOURS · 4 NOT_ALLOWED (buy: not on the current allowlist; sell: never
///           allowed) · 5 OVER_TRADE_CAP · 6 OVER_DAY_CAP · 7 NOT_QUOTE_PAIR · 8 SLIPPAGE
///         Caps are in USDG base units (6 dec). The notional of a buy is the USDG spent, of a sell the USDG received —
///         only known after the swap, so sells (and partially filled buys) are checked inside a rolled-back self-call:
///         no tokens move on a refusal.
contract WritVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ───────────────────────────── types ─────────────────────────────

    /// @dev Hours are UTC, [activeFrom, activeTo); activeFrom > activeTo wraps past midnight; 0→24 = always.
    ///      expiry 0 = never expires.
    struct Writ {
        uint256 maxPerTrade;
        uint256 maxPerDay;
        uint8 activeFrom;
        uint8 activeTo;
        uint64 expiry;
        uint16 maxSlippageBps;
        bool quashed;
    }

    uint8 public constant QUASHED = 1;
    uint8 public constant EXPIRED = 2;
    uint8 public constant OFF_HOURS = 3;
    uint8 public constant NOT_ALLOWED = 4;
    uint8 public constant OVER_TRADE_CAP = 5;
    uint8 public constant OVER_DAY_CAP = 6;
    uint8 public constant NOT_QUOTE_PAIR = 7;
    uint8 public constant SLIPPAGE = 8;

    /// @notice Upper bound the owner may set for maxSlippageBps (10 %).
    uint16 public constant MAX_SLIPPAGE_LIMIT = 1000;
    /// @notice Longest reason (bytes) an agent may attach to a trade. Longer = malformed call (revert).
    uint256 public constant MAX_REASON = 280;
    /// @notice TWAP window for the slippage guard (seconds). Shortened to the pool's oldest observation if younger.
    uint32 public constant TWAP_WINDOW = 300;

    ISwapRouter02 public immutable router;
    IUniswapV3Factory public immutable v3Factory;
    address public immutable usdg;
    /// @notice Runtime codehash every allowed stock must have (the official Robinhood stock-token BeaconProxy), so a
    ///         look-alike token with the same symbol can never be allowed. bytes32(0) disables the check (tests only).
    bytes32 public immutable stockCodehash;
    /// @notice The WritFactory that opened this vault (the indexer only trusts vaults it lists).
    address public immutable writFactory;

    // ──────────────────────────── storage ────────────────────────────

    /// @notice The agent key. May only call `execute`.
    address public agent;
    /// @notice Number of executes so far (fills + refusals). The n-th execute emits seq = n.
    uint256 public seq;
    /// @notice USDG notional settled per UTC day (day = block.timestamp / 1 days).
    mapping(uint256 day => uint256 notional) public spentOn;

    /// @notice The one Uniswap v3 USDG pool each stock may trade through (and whose TWAP prices the slippage guard).
    mapping(address stock => address pool) public pinnedPool;
    mapping(address stock => uint24 fee) public poolFee;

    Writ internal _writ;
    EnumerableSet.AddressSet internal _allowed;
    /// @dev every token that was ever allowed (so withdrawAll can sweep tokens that left the allowlist).
    EnumerableSet.AddressSet internal _seen;

    // ───────────────────────────── events ────────────────────────────
    // Filed / Refused are a FIXED interface (server indexer, MCP, browser verifier). Do not change.

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

    event Quashed(bool quashed);
    event WritSet(
        uint256 maxPerTrade, uint256 maxPerDay, uint8 activeFrom, uint8 activeTo, uint64 expiry, uint16 maxSlippageBps
    );
    event Allowed(address indexed token, bool ok);
    event AgentSet(address indexed agent);
    event PoolPinned(address indexed stock, address indexed pool, uint24 fee);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    // ───────────────────────────── errors ────────────────────────────

    error NotAgent();
    error OnlySelf();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(address token, uint256 have, uint256 need);
    error ReasonTooLong(uint256 length);
    error BadWrit();
    error BadToken(address token);
    error NotStockToken(address token);
    error NoPool(address stock, uint24 fee);
    error RoleClash();
    error RenounceDisabled();
    /// @dev the swap leg reverted with no data (almost always: out of gas) — not a refusal; raise the gas limit.
    error SwapOutOfGas();
    /// @dev internal: thrown inside the rolled-back self-call to carry a refusal code out of try/catch.
    error Refusal(uint8 code);

    modifier onlyAgent() {
        if (msg.sender != agent) revert NotAgent();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @param fees_ fees_[i] pins that fee tier's pool for allow_[i]; 0 (or a short array) = deepest tier now.
    constructor(
        address router_,
        address v3Factory_,
        address usdg_,
        bytes32 stockCodehash_,
        address owner_,
        address agent_,
        Writ memory writ_,
        address[] memory allow_,
        uint24[] memory fees_
    ) Ownable(owner_) {
        if (router_ == address(0) || v3Factory_ == address(0) || usdg_ == address(0)) revert ZeroAddress();
        if (agent_ == address(0)) revert ZeroAddress();
        if (agent_ == owner_) revert RoleClash();
        router = ISwapRouter02(router_);
        v3Factory = IUniswapV3Factory(v3Factory_);
        usdg = usdg_;
        stockCodehash = stockCodehash_;
        writFactory = msg.sender;
        agent = agent_;
        emit AgentSet(agent_);
        _setWrit(writ_);
        if (writ_.quashed) emit Quashed(true);
        for (uint256 i; i < allow_.length; ++i) {
            if (i < fees_.length && fees_[i] != 0) _pin(allow_[i], fees_[i]);
            _allow(allow_[i], true);
        }
    }

    // ──────────────────────────── trading ────────────────────────────

    /// @notice Trade `amountIn` of `tokenIn` for at least `minOut` of `tokenOut`. Exactly one side must be USDG, the
    ///         other an allowed stock. A writ breach emits `Refused` and returns.
    /// @param fee    the Uniswap v3 fee tier — must be the stock's pinned tier (`poolFee(stock)`).
    /// @param reason the agent's one-line reason, published on-chain in the event (≤ MAX_REASON bytes).
    /// @return code      0 = filed (swap settled), else the refusal code
    /// @return amountOut tokens received (0 on refusal)
    function execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint24 fee,
        string calldata reason
    ) external onlyAgent nonReentrant returns (uint8 code, uint256 amountOut) {
        // Malformed calls are not writ breaches → plain revert (nothing to prove on-chain).
        if (amountIn == 0) revert ZeroAmount();
        if (bytes(reason).length > MAX_REASON) revert ReasonTooLong(bytes(reason).length);
        uint256 bal = IERC20(tokenIn).balanceOf(address(this));
        if (bal < amountIn) revert InsufficientBalance(tokenIn, bal, amountIn);

        uint256 s = ++seq;
        uint256 day = block.timestamp / 1 days;
        uint256 notional;
        (code, amountOut, notional) = _trade(tokenIn, tokenOut, amountIn, minOut, fee, day);
        if (code != 0) {
            emit Refused(s, code, tokenIn, tokenOut, amountIn, reason);
            return (code, 0);
        }
        uint256 spent = spentOn[day] + notional;
        spentOn[day] = spent;
        emit Filed(
            s, tokenIn, tokenOut, amountIn, amountOut, notional, spent, _writ.maxPerTrade, _writ.maxPerDay, reason
        );
    }

    function _trade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint24 fee, uint256 day)
        internal
        returns (uint8 code, uint256 amountOut, uint256 notional)
    {
        code = _precheck(_writ, tokenIn, tokenOut, amountIn, day);
        if (code != 0) return (code, 0, 0);

        bool isBuy = tokenIn == usdg;
        address stock = isBuy ? tokenOut : tokenIn;
        if (fee != poolFee[stock]) return (NOT_QUOTE_PAIR, 0, 0); // only the pinned pool
        address pool = pinnedPool[stock];

        (uint256 expectedOut,) = _twapQuote(pool, fee, tokenIn, tokenOut, amountIn);
        if (minOut == 0 || minOut < _floor(expectedOut, _writ.maxSlippageBps)) return (SLIPPAGE, 0, 0);

        try this.selfSwap(tokenIn, tokenOut, fee, amountIn, minOut, !isBuy, day) returns (uint256 out) {
            amountOut = out;
            notional = isBuy ? amountIn : out;
        } catch (bytes memory err) {
            code = _refusalFrom(err);
        }
    }

    /// @notice Internal swap leg. External only so `execute` can roll it back with try/catch; callable by this
    ///         contract only.
    /// @dev Reverts `Refusal(5|6)` if a sell's realised USDG out breaks the caps, `Refusal(8)` if output < minOut;
    ///      the router's "Too little received" is mapped to SLIPPAGE by the caller, any other revert is re-thrown.
    function selfSwap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut,
        bool isSell,
        uint256 day
    ) external onlySelf returns (uint256 out) {
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
        out = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (out < minOut) revert Refusal(SLIPPAGE);
        if (isSell) _checkCaps(out, day);
    }

    // ───────────────────────────── views ─────────────────────────────

    function writ() external view returns (Writ memory) {
        return _writ;
    }

    function allowList() external view returns (address[] memory) {
        return _allowed.values();
    }

    function allowed(address token) external view returns (bool) {
        return _allowed.contains(token);
    }

    /// @notice Every token ever allowed (what withdrawAll sweeps besides USDG).
    function seenTokens() external view returns (address[] memory) {
        return _seen.values();
    }

    /// @notice True if `token` was ever on the allowlist. Such a token may always be SOLD (inside every other gate);
    ///         buying requires it to be on the current allowlist.
    function everAllowed(address token) external view returns (bool) {
        return _seen.contains(token);
    }

    function today() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function spentToday() external view returns (uint256) {
        return spentOn[today()];
    }

    /// @notice USDG the agent may still spend (or receive from sells) today, ignoring the per-trade cap.
    function leftToday() external view returns (uint256) {
        uint256 spent = spentOn[today()];
        return spent >= _writ.maxPerDay ? 0 : _writ.maxPerDay - spent;
    }

    /// @notice True if an execute right now would pass the quash / expiry / hours gates.
    function isActive() external view returns (bool) {
        Writ memory w = _writ;
        return !w.quashed && !(w.expiry != 0 && block.timestamp >= w.expiry) && _inHours(w.activeFrom, w.activeTo);
    }

    /// @notice What the slippage guard will accept for a stock <-> USDG trade through the pinned pool: the
    ///         TWAP-expected output (net of the LP fee), the minimum `minOut` allowed, and the `fee` to pass to
    ///         `execute`. Agents should quote (QuoterV2), then pass max(quote * (1 - own tolerance), minOutFloor).
    function quoteTwap(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 expectedOut, uint256 minOutFloor, uint24 fee, uint32 windowUsed)
    {
        address stock = tokenIn == usdg ? tokenOut : tokenIn;
        address pool = pinnedPool[stock];
        if (pool == address(0) || (tokenIn == usdg) == (tokenOut == usdg)) return (0, 0, 0, 0);
        fee = poolFee[stock];
        (expectedOut, windowUsed) = _twapQuote(pool, fee, tokenIn, tokenOut, amountIn);
        minOutFloor = _floor(expectedOut, _writ.maxSlippageBps);
    }

    // ───────────────────────────── owner ─────────────────────────────

    function setWrit(Writ calldata w) external onlyOwner {
        bool was = _writ.quashed;
        _setWrit(w);
        if (was != w.quashed) emit Quashed(w.quashed);
    }

    function setAllowed(address[] calldata tokens, bool ok) external onlyOwner {
        for (uint256 i; i < tokens.length; ++i) {
            _allow(tokens[i], ok);
        }
    }

    /// @notice Replace the whole allowlist in one call. Stocks that leave it can still be sold (`everAllowed`).
    function replaceAllowList(address[] calldata tokens) external onlyOwner {
        address[] memory old = _allowed.values();
        for (uint256 i; i < old.length; ++i) {
            _allowed.remove(old[i]);
            emit Allowed(old[i], false);
        }
        for (uint256 i; i < tokens.length; ++i) {
            _allow(tokens[i], true);
        }
    }

    /// @notice The kill switch: every execute is refused (code 1) until `unquash`.
    function quash() external onlyOwner {
        _writ.quashed = true;
        emit Quashed(true);
    }

    function unquash() external onlyOwner {
        _writ.quashed = false;
        emit Quashed(false);
    }

    function setAgent(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        if (a == owner()) revert RoleClash();
        agent = a;
        emit AgentSet(a);
    }

    /// @notice Pin `stock` to the USDG pool at `fee` (must exist in the Uniswap v3 factory).
    function setPoolFee(address stock, uint24 fee) external onlyOwner {
        if (stock == address(0) || stock == usdg) revert BadToken(stock);
        _pin(stock, fee);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Sweep USDG and every token that was ever on the allowlist to `to`.
    function withdrawAll(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _sweep(usdg, to);
        uint256 n = _seen.length();
        for (uint256 i; i < n; ++i) {
            _sweep(_seen.at(i), to);
        }
    }

    /// @dev Renouncing would lock the vault forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev The agent may never become the owner.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == agent) revert RoleClash();
        super.transferOwnership(newOwner);
    }

    // ─────────────────────────── internals ───────────────────────────

    /// @dev Gates 1, 2, 3, 4, 5/6 (buys), 7. Pool, slippage and sell caps follow in `_trade`.
    function _precheck(Writ memory w, address tokenIn, address tokenOut, uint256 amountIn, uint256 day)
        internal
        view
        returns (uint8)
    {
        if (w.quashed) return QUASHED;
        if (w.expiry != 0 && block.timestamp >= w.expiry) return EXPIRED;
        if (!_inHours(w.activeFrom, w.activeTo)) return OFF_HOURS;
        bool inQ = tokenIn == usdg;
        bool outQ = tokenOut == usdg;
        // Buys: the stock must be on today's allowlist. Sells: any stock that was EVER allowed (a position left over
        // after the owner narrows the allowlist can still be unwound by the agent).
        if ((!inQ && !_seen.contains(tokenIn)) || (!outQ && !_allowed.contains(tokenOut))) return NOT_ALLOWED;
        // Caps need a USDG side; for sells they are checked on the realised USDG out inside the self-call.
        if (inQ && !outQ) {
            if (amountIn > w.maxPerTrade) return OVER_TRADE_CAP;
            if (spentOn[day] + amountIn > w.maxPerDay) return OVER_DAY_CAP;
        }
        if (inQ == outQ) return NOT_QUOTE_PAIR; // stock→stock or USDG→USDG
        return 0;
    }

    /// @dev Inside the self-call, after the swap: realised notional must fit the caps.
    function _checkCaps(uint256 notional, uint256 day) internal view {
        if (notional > _writ.maxPerTrade) revert Refusal(OVER_TRADE_CAP);
        if (spentOn[day] + notional > _writ.maxPerDay) revert Refusal(OVER_DAY_CAP);
    }

    function _inHours(uint8 from, uint8 to) internal view returns (bool) {
        if (from == 0 && to == 24) return true;
        uint256 h = (block.timestamp % 1 days) / 1 hours;
        if (from < to) return h >= from && h < to;
        return h >= from || h < to; // window wraps past midnight UTC
    }

    function _floor(uint256 expectedOut, uint16 bps) internal pure returns (uint256) {
        return expectedOut * (10_000 - bps) / 10_000;
    }

    /// @dev SwapRouter02 (v3 exactInputSingle): require(amountOut >= amountOutMinimum, "Too little received").
    bytes32 internal constant V3_TOO_LITTLE = keccak256(abi.encodeWithSignature("Error(string)", "Too little received"));

    /// @dev Maps a failed swap self-call to a refusal code: our own Refusal(5|6|8) or the router's slippage error →
    ///      that code. ANY other failure (out of gas, a token transfer failing, a paused stock, …) is not a writ breach
    ///      and is re-thrown, reverting the whole execute — otherwise eth_estimateGas could settle on a gas limit at
    ///      which the swap runs out of gas inside the router and every execute "refuses" (seen on an RC fork, 160).
    function _refusalFrom(bytes memory err) internal pure returns (uint8) {
        if (err.length == 0) revert SwapOutOfGas();
        bytes4 sel = bytes4(err);
        if (sel == Refusal.selector && err.length == 36) {
            uint256 c;
            assembly ("memory-safe") {
                c := mload(add(err, 36))
            }
            if (c == OVER_TRADE_CAP || c == OVER_DAY_CAP || c == SLIPPAGE) return uint8(c);
        }
        if (keccak256(err) == V3_TOO_LITTLE) return SLIPPAGE;
        assembly ("memory-safe") {
            revert(add(err, 32), mload(err))
        }
    }

    function _setWrit(Writ memory w) internal {
        if (
            w.activeFrom > 23 || w.activeTo > 24 || w.activeFrom == w.activeTo || w.maxSlippageBps > MAX_SLIPPAGE_LIMIT
                || w.maxPerTrade == 0 || w.maxPerTrade > w.maxPerDay
        ) revert BadWrit();
        _writ = w;
        emit WritSet(w.maxPerTrade, w.maxPerDay, w.activeFrom, w.activeTo, w.expiry, w.maxSlippageBps);
    }

    function _allow(address token, bool ok) internal {
        if (token == address(0) || token == usdg) revert BadToken(token);
        if (ok) {
            if (stockCodehash != bytes32(0) && token.codehash != stockCodehash) revert NotStockToken(token);
            if (pinnedPool[token] == address(0)) _pinDeepest(token);
            _allowed.add(token);
            _seen.add(token);
        } else {
            _allowed.remove(token);
        }
        emit Allowed(token, ok);
    }

    /// @dev Output at the pool's TWAP price, net of the pool's LP fee (so maxSlippageBps measures price movement and
    ///      impact only).
    function _twapQuote(address pool, uint24 fee, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 expectedOut, uint32 windowUsed)
    {
        int24 tick;
        (tick, windowUsed) = TwapOracle.meanTick(pool, TWAP_WINDOW);
        expectedOut = TwapOracle.quoteAtTick(tick, amountIn, tokenIn, tokenOut) * (1_000_000 - fee) / 1_000_000;
    }

    function _pin(address stock, uint24 fee) internal {
        address pool = v3Factory.getPool(stock, usdg, fee);
        if (pool == address(0)) revert NoPool(stock, fee);
        pinnedPool[stock] = pool;
        poolFee[stock] = fee;
        emit PoolPinned(stock, pool, fee);
    }

    /// @dev Deepest of the standard fee tiers by in-range liquidity (only used when no tier was pinned explicitly).
    function _pinDeepest(address stock) internal {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10000];
        uint24 best;
        uint128 bestLiq;
        for (uint256 i; i < 4; ++i) {
            address pool = v3Factory.getPool(stock, usdg, tiers[i]);
            if (pool == address(0)) continue;
            uint128 liq = IUniswapV3PoolLike(pool).liquidity();
            if (best == 0 || liq > bestLiq) (best, bestLiq) = (tiers[i], liq);
        }
        if (best == 0) revert NoPool(stock, 0);
        _pin(stock, best);
    }

    function _sweep(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit Withdrawn(token, to, bal);
        }
    }
}
