// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RoboBetToken} from "../src/RoboBetToken.sol";
import {DeployRoboBetToken} from "../script/DeployRoboBetToken.s.sol";

contract RoboBetTokenTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    RoboBetToken token;
    address deployer = address(0xFAC7);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.prank(deployer);
        token = new RoboBetToken();
    }

    // --- metadata and supply ---

    function test_metadata() public view {
        assertEq(token.name(), "ROBOBET");
        assertEq(token.symbol(), "ROBOBET");
        assertEq(token.decimals(), 18);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsMintEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new RoboBetToken();
    }

    function test_deployScriptMintsToCaller() public {
        DeployRoboBetToken script = new DeployRoboBetToken();
        RoboBetToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    // --- transfers ---

    function test_transfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(deployer, alice, 100e18);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 100e18));
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 100e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeSupplyArrivesExactly() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(alice);
        token.transfer(bob, 11);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    // --- allowances ---

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(deployer, alice, 50e18);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 50e18));
        assertEq(token.allowance(deployer, alice), 50e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 20e18));
        assertEq(token.balanceOf(bob), 20e18);
        assertEq(token.allowance(deployer, alice), 30e18);
    }

    function test_infiniteAllowanceIsNotSpent() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 5, 6));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 6);
    }

    function test_RevertWhen_transferFromWithoutApproval() public {
        vm.prank(deployer);
        token.transfer(alice, 1e18);
        // The deployer holds no special power over other holders.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    // --- no privileged supply or balance control ---

    function test_noMintOrAdminFunctions() public {
        string[8] memory sigs = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "owner()",
            "transferOwnership(address)",
            "blacklist(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // --- fuzz ---

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance_);
        vm.prank(alice);
        if (amount > allowance_) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance_, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            token.transferFrom(deployer, bob, amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, alice), allowance_ - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
