// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WritVault} from "./WritVault.sol";

/// @title  WritFactory — anyone opens a WritVault for their own AI agent.
/// @notice `open` deploys a WritVault owned by the caller, with the caller's agent key, writ and allowlist. The factory
///         holds no funds and has no owner; the venue (router, Uniswap v3 factory, USDG) and the stock-token codehash
///         are fixed at deploy, so every vault it lists trades the same official markets. The public docket indexes
///         `WritOpened` and then each listed vault's `Filed` / `Refused`.
contract WritFactory {
    address public immutable router;
    address public immutable v3Factory;
    address public immutable usdg;
    bytes32 public immutable stockCodehash;

    address[] internal _vaults;
    mapping(address owner => address[] vaults) internal _byOwner;
    /// @notice True for every vault this factory opened.
    mapping(address vault => bool) public isWrit;

    event WritOpened(uint256 indexed id, address indexed owner, address indexed vault, address agent);

    error ZeroAddress();

    constructor(address router_, address v3Factory_, address usdg_, bytes32 stockCodehash_) {
        if (router_ == address(0) || v3Factory_ == address(0) || usdg_ == address(0)) revert ZeroAddress();
        router = router_;
        v3Factory = v3Factory_;
        usdg = usdg_;
        stockCodehash = stockCodehash_;
    }

    /// @notice Open a vault owned by msg.sender. Fund it afterwards with a plain USDG transfer.
    /// @param fees fees[i] pins that Uniswap v3 fee tier for allow[i]; 0 (or a short array) = deepest tier now.
    function open(address agent, WritVault.Writ calldata writ, address[] calldata allow, uint24[] calldata fees)
        external
        returns (address vault)
    {
        vault = address(new WritVault(router, v3Factory, usdg, stockCodehash, msg.sender, agent, writ, allow, fees));
        uint256 id = _vaults.length;
        _vaults.push(vault);
        _byOwner[msg.sender].push(vault);
        isWrit[vault] = true;
        emit WritOpened(id, msg.sender, vault, agent);
    }

    function count() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 id) external view returns (address) {
        return _vaults[id];
    }

    /// @notice Vaults [from, from + n) — clipped to the end.
    function vaults(uint256 from, uint256 n) external view returns (address[] memory out) {
        uint256 len = _vaults.length;
        if (from >= len) return out;
        if (n > len - from) n = len - from;
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _vaults[from + i];
        }
    }

    /// @notice Vaults opened by `owner` (the opener; a later ownership transfer is not reflected here).
    function vaultsOf(address owner) external view returns (address[] memory) {
        return _byOwner[owner];
    }
}
