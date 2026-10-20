// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {WritFactory} from "../src/WritFactory.sol";

/// Deploys the one WritFactory on Robinhood Chain mainnet. Vaults are opened later by their owners (web /open, or
/// script/OpenWrit.s.sol for the house writ).
///   forge script script/Deploy.s.sol:Deploy --rpc-url robinhood --chain 4663 [--broadcast --verify --verifier sourcify]
contract Deploy is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02 (exactInputSingle, no deadline)
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    /// Runtime codehash of the official stock-token BeaconProxy (NVDA, TSLA, SPY on 2026-10-20).
    bytes32 constant STOCK_CODEHASH = 0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    function run() external returns (WritFactory wf) {
        require(block.chainid == 4663, "not Robinhood Chain mainnet");
        require(NVDA.codehash == STOCK_CODEHASH, "stock codehash changed: re-read it before deploying");
        require(USDG.code.length > 0 && ROUTER.code.length > 0 && V3_FACTORY.code.length > 0, "venue missing");
        vm.startBroadcast();
        wf = new WritFactory(ROUTER, V3_FACTORY, USDG, STOCK_CODEHASH);
        vm.stopBroadcast();
        console2.log("WritFactory:", address(wf));
    }
}
