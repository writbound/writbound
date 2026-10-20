// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WritFactory} from "../src/WritFactory.sol";
import {WritVault} from "../src/WritVault.sol";
import {MockERC20, MockPool, MockFactory, MockRouter} from "./mocks/Mocks.sol";

contract WritFactoryTest is Test {
    event WritOpened(uint256 indexed id, address indexed owner, address indexed vault, address agent);

    uint256 constant USD = 1e6;
    uint24 constant FEE = 500;

    MockERC20 usdg;
    MockERC20 nvda;
    MockFactory v3;
    MockRouter router;
    WritFactory wf;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address aliceAgent = makeAddr("aliceAgent");
    address bobAgent = makeAddr("bobAgent");

    function setUp() public {
        vm.warp(1_792_454_400 + 15 hours); // 2026-10-21 15:00 UTC
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVIDIA", "NVDA", 18);
        v3 = new MockFactory();
        router = new MockRouter(v3);
        MockPool p = new MockPool(address(usdg), address(nvda), FEE, address(usdg) < address(nvda) ? int24(207244) : int24(-207244));
        v3.setPool(address(usdg), address(nvda), FEE, address(p));
        wf = new WritFactory(address(router), address(v3), address(usdg), address(nvda).codehash);
    }

    function _w() internal pure returns (WritVault.Writ memory) {
        return WritVault.Writ(10 * USD, 25 * USD, 13, 20, 0, 100, false);
    }

    function _open(address who, address agent) internal returns (WritVault v) {
        address[] memory allow = new address[](1);
        allow[0] = address(nvda);
        uint24[] memory fees = new uint24[](1);
        fees[0] = FEE;
        vm.prank(who);
        v = WritVault(wf.open(agent, _w(), allow, fees));
    }

    function test_openOwnedByCaller() public {
        vm.expectEmit(true, true, false, true, address(wf));
        emit WritOpened(0, alice, address(0), aliceAgent);
        // vault address is not known before; check the rest via the registry
        WritVault v;
        {
            address[] memory allow = new address[](1);
            allow[0] = address(nvda);
            vm.prank(alice);
            v = WritVault(wf.open(aliceAgent, _w(), allow, new uint24[](0)));
        }
        assertEq(v.owner(), alice);
        assertEq(v.agent(), aliceAgent);
        assertEq(v.writFactory(), address(wf));
        assertEq(v.stockCodehash(), address(nvda).codehash);
        assertEq(address(v.router()), address(router));
        assertEq(v.usdg(), address(usdg));
        assertTrue(v.allowed(address(nvda)));
        assertEq(v.poolFee(address(nvda)), FEE);
        WritVault.Writ memory w = v.writ();
        assertEq(w.maxPerDay, 25 * USD);
        assertEq(w.activeFrom, 13);
    }

    function test_registry() public {
        WritVault a = _open(alice, aliceAgent);
        WritVault b = _open(bob, bobAgent);
        WritVault a2 = _open(alice, bobAgent);
        assertEq(wf.count(), 3);
        assertEq(wf.vaultAt(1), address(b));
        assertTrue(wf.isWrit(address(a)));
        assertFalse(wf.isWrit(alice));
        address[] memory mine = wf.vaultsOf(alice);
        assertEq(mine.length, 2);
        assertEq(mine[0], address(a));
        assertEq(mine[1], address(a2));
        address[] memory page = wf.vaults(1, 10);
        assertEq(page.length, 2);
        assertEq(page[0], address(b));
        assertEq(wf.vaults(3, 10).length, 0);
        assertEq(wf.vaults(0, 1).length, 1);
    }

    /// One owner's agent cannot touch another owner's vault; owners are isolated.
    function test_vaultsAreIsolated() public {
        WritVault a = _open(alice, aliceAgent);
        WritVault b = _open(bob, bobAgent);
        usdg.mint(address(a), 50 * USD);
        usdg.mint(address(b), 50 * USD);
        vm.prank(bobAgent);
        vm.expectRevert(WritVault.NotAgent.selector);
        a.execute(address(usdg), address(nvda), USD, 1, FEE, "not mine");
        vm.prank(bob);
        vm.expectRevert();
        a.withdrawAll(bob);
        assertEq(usdg.balanceOf(address(a)), 50 * USD);
    }

    function test_openGuards() public {
        address[] memory allow = new address[](0);
        vm.prank(alice);
        vm.expectRevert(WritVault.RoleClash.selector);
        wf.open(alice, _w(), allow, new uint24[](0));
        vm.prank(alice);
        vm.expectRevert(WritVault.BadWrit.selector);
        wf.open(aliceAgent, WritVault.Writ(0, 25 * USD, 13, 20, 0, 100, false), allow, new uint24[](0));
        vm.expectRevert(WritFactory.ZeroAddress.selector);
        new WritFactory(address(0), address(v3), address(usdg), bytes32(0));
        assertEq(wf.count(), 0);
    }
}
