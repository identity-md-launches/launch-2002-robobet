// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RoboBetToken} from "../src/RoboBetToken.sol";

/// @notice Deploys the token from inside a contract, as the ProjectFactory does on launch, so the
/// minted supply lands on a contract rather than an EOA.
contract FactoryStandIn {
    RoboBetToken public token;

    function launch() external returns (RoboBetToken) {
        token = new RoboBetToken();
        return token;
    }

    function move(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Edge cases and failure paths beyond the base suite: zero and self transfers, allowance
/// corner cases, the exact launch flows, unknown selectors, ETH, events, and the bytecode floor.
/// forge-config: default.fuzz.runs = 1000
contract RoboBetTokenEdgeTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 8_000;

    RoboBetToken token;
    address deployer = address(0xFAC7);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.prank(deployer);
        token = new RoboBetToken();
    }

    // ------------------------------------------------------------------------------------------
    // supply and construction
    // ------------------------------------------------------------------------------------------

    function test_supplyIsExactlyOneBillionTimesTenToTheEighteen() public view {
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.totalSupply(), 1e9 * 10 ** uint256(token.decimals()));
    }

    /// @dev Whoever deploys receives the whole supply: an EOA, a contract, any address.
    function testFuzz_wholeSupplyMintedToWhoeverDeploys(address who) public {
        vm.assume(who != address(0));
        vm.assume(who.code.length == 0);
        vm.assume(who != alice);
        vm.prank(who);
        RoboBetToken t = new RoboBetToken();
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(who), SUPPLY);
        assertEq(t.balanceOf(alice), 0);
        // The first token's ledger is untouched by the second deployment.
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev On launch the deployer is the factory, a contract. The supply must land on it and move
    /// out of it exactly, since the factory forwards it to the distributor, the pool and the requester.
    function test_contractDeployerHoldsAndForwardsSupplyExactly() public {
        FactoryStandIn factory = new FactoryStandIn();
        RoboBetToken t = factory.launch();
        assertEq(t.balanceOf(address(factory)), SUPPLY);

        address distributor = address(0xD157);
        address pool = address(0x900C);
        address requester = address(0x12A7);
        uint256 swarm = SUPPLY * SWARM_BPS / 10_000;
        uint256 pooled = SUPPLY * POOL_BPS / 10_000;
        uint256 rest = SUPPLY - swarm - pooled;

        assertTrue(factory.move(distributor, swarm));
        assertTrue(factory.move(pool, pooled));
        assertTrue(factory.move(requester, rest));

        assertEq(t.balanceOf(distributor), swarm, "swarm share short");
        assertEq(t.balanceOf(pool), pooled, "pool share short");
        assertEq(t.balanceOf(requester), rest, "remainder short");
        assertEq(t.balanceOf(address(factory)), 0, "factory kept something");
        assertEq(swarm + pooled + rest, SUPPLY);
        assertEq(t.totalSupply(), SUPPLY);

        // A claim from the distributor arrives whole too.
        address claimant = address(0xC1A1);
        vm.prank(distributor);
        assertTrue(t.transfer(claimant, swarm));
        assertEq(t.balanceOf(claimant), swarm);
        assertEq(t.balanceOf(distributor), 0);
    }

    /// @dev Two deployments are two independent supplies; neither can touch the other.
    function test_secondDeploymentIsIndependent() public {
        vm.prank(alice);
        RoboBetToken other = new RoboBetToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(other.balanceOf(deployer), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        vm.prank(deployer);
        other.transfer(bob, 1);
    }

    // ------------------------------------------------------------------------------------------
    // transfer edges
    // ------------------------------------------------------------------------------------------

    function test_transferZeroSucceedsAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0);
        vm.prank(alice); // alice holds nothing; a zero transfer is still allowed
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfLeavesBalanceUnchanged() public {
        vm.prank(deployer);
        token.transfer(alice, 500);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 500));
        assertEq(token.balanceOf(alice), 500);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhen_transferToSelfExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 500);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 500, 501));
        vm.prank(alice);
        token.transfer(alice, 501);
    }

    function test_RevertWhen_transferOneWeiFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_RevertWhen_transferMaxUint() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
    }

    function test_RevertWhen_transferSupplyPlusOne() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        vm.prank(deployer);
        token.transfer(alice, SUPPLY + 1);
    }

    function test_RevertWhen_transferZeroToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 0);
    }

    function test_transferToTokenItselfIsAllowedButStranded() public {
        // Nothing in the token forbids this; the balance is simply unrecoverable. Documented, not a defect.
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 1));
        assertEq(token.balanceOf(address(token)), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Full supply round trip: deployer -> alice -> bob -> deployer, exact at every hop.
    function test_wholeSupplyRoundTripIsExact() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        vm.prank(alice);
        token.transfer(bob, SUPPLY);
        vm.prank(bob);
        token.transfer(deployer, SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Chained transfers through many recipients conserve the supply exactly.
    function testFuzz_chainedTransfersConserveSupply(uint8 hops, uint256 amountSeed) public {
        hops = uint8(bound(hops, 1, 32));
        uint256 amount = bound(amountSeed, 0, SUPPLY);
        address prev = deployer;
        for (uint256 i = 1; i <= hops; ++i) {
            address next = address(uint160(0x1000 + i));
            vm.prank(prev);
            assertTrue(token.transfer(next, amount));
            assertEq(token.balanceOf(prev), prev == deployer ? SUPPLY - amount : 0);
            assertEq(token.balanceOf(next), amount);
            prev = next;
        }
        assertEq(token.balanceOf(prev) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Splitting the supply across many holders and summing their balances gives the supply back.
    function testFuzz_splitAcrossHoldersSumsToSupply(uint256[8] memory shares) public {
        uint256 remaining = SUPPLY;
        uint256 sum;
        for (uint256 i; i < 8; ++i) {
            uint256 amount = bound(shares[i], 0, remaining);
            address holder = address(uint160(0x2000 + i));
            vm.prank(deployer);
            token.transfer(holder, amount);
            remaining -= amount;
            sum += token.balanceOf(holder);
        }
        assertEq(sum + token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(deployer), remaining);
    }

    /// @dev Any amount above the sender's balance reverts with the exact ERC-6093 error, and nothing moves.
    function testFuzz_transferAboveBalanceRevertsExactly(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------------------------------------
    // allowance edges
    // ------------------------------------------------------------------------------------------

    function test_approveOverwritesNotAccumulates() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        token.approve(alice, 40);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 40);
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        vm.expectEmit(true, true, false, true);
        emit Approval(deployer, alice, 0);
        assertTrue(token.approve(alice, 0));
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    function test_approveCanExceedBalance() public {
        // An allowance is a promise, not a reservation: it may exceed what the owner holds.
        vm.prank(alice);
        assertTrue(token.approve(bob, SUPPLY));
        assertEq(token.allowance(alice, bob), SUPPLY);
        // but spending it still fails on balance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), SUPPLY, "allowance must not be consumed by a failed transfer");
    }

    function test_RevertWhen_infiniteAllowanceButInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(bob);
        token.transferFrom(alice, bob, 11);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_allowanceCheckedBeforeBalance() public {
        // alice has nothing and bob has no allowance: the allowance error wins.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromZeroAmountWithZeroAllowance() public {
        // Zero spends nothing and so needs no allowance.
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(deployer);
        token.approve(alice, 77);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 77);
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromToOwnerSelfConsumesAllowanceOnly() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, deployer, 10));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_transferFromBySpenderToItself() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, alice, 10));
        assertEq(token.balanceOf(alice), 10);
    }

    function test_selfApprovalBehavesLikeAnyOther() public {
        vm.prank(deployer);
        token.approve(deployer, 5);
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 5);
        assertEq(token.allowance(deployer, deployer), 0);
        assertEq(token.balanceOf(alice), 5);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        vm.prank(deployer);
        token.approve(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(deployer, address(0), 1);
    }

    function test_RevertWhen_transferFromZeroAddressOwner() public {
        // Nobody can be approved by address(0), so pulling from it fails on allowance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(0), bob, 1);
    }

    function test_transferFromDoesNotEmitApproval() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), deployer);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 4);
    }

    /// @dev Allowances are per (owner, spender): one spender's draw never touches another's.
    function test_allowancesAreIndependentPerSpender() public {
        vm.startPrank(deployer);
        token.approve(alice, 30);
        token.approve(bob, 20);
        vm.stopPrank();
        vm.prank(alice);
        token.transferFrom(deployer, alice, 30);
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.allowance(deployer, bob), 20);
        assertEq(token.allowance(alice, deployer), 0);
    }

    /// @dev Repeated partial draws against one allowance are exact until it is spent, then refused.
    function testFuzz_repeatedDrawsExhaustAllowanceExactly(uint256 allowance_, uint8 draws) public {
        allowance_ = bound(allowance_, 1, SUPPLY);
        draws = uint8(bound(draws, 1, 16));
        vm.prank(deployer);
        token.approve(alice, allowance_);
        uint256 spent;
        uint256 each = allowance_ / draws;
        for (uint256 i; i < draws; ++i) {
            vm.prank(alice);
            token.transferFrom(deployer, bob, each);
            spent += each;
            assertEq(token.allowance(deployer, alice), allowance_ - spent);
        }
        uint256 left = allowance_ - spent;
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, left, left + 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, left + 1);
        assertEq(token.balanceOf(bob), spent);
        assertEq(token.balanceOf(deployer), SUPPLY - spent);
    }

    /// @dev Approve from any owner to any non-zero spender records exactly that value.
    function testFuzz_approveRecordsExactly(address owner, address spender, uint256 amount) public {
        vm.assume(owner != address(0) && spender != address(0));
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    /// @dev The zero address can never be an approver (nor can anyone impersonate it to grant allowances).
    function test_RevertWhen_approveFromZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(alice, 1);
    }

    // ------------------------------------------------------------------------------------------
    // no privileged surface, no fallback, no ETH
    // ------------------------------------------------------------------------------------------

    function test_RevertWhen_sendingEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token must not accept ETH");
        assertEq(address(token).balance, 0);
    }

    function test_RevertWhen_sendingEtherWithTransferCalldata() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transfer, (alice, 1)));
        assertFalse(ok, "non-payable transfer must reject value");
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes memory args) public {
        vm.assume(
            selector != IERC20.transfer.selector && selector != IERC20.transferFrom.selector
                && selector != IERC20.approve.selector && selector != IERC20.allowance.selector
                && selector != IERC20.balanceOf.selector && selector != IERC20.totalSupply.selector
                && selector != IERC20Metadata.name.selector && selector != IERC20Metadata.symbol.selector
                && selector != IERC20Metadata.decimals.selector && selector != bytes4(keccak256("TOTAL_SUPPLY()"))
        );
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "unknown selector must revert (no fallback)");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The wider list the launch floor tries, from a stranger and from the deployer: none may
    /// grow the supply, credit the caller, or move or freeze a holder.
    function test_floorAdminSelectorsAreInert() public {
        address holder = address(0x401D);
        vm.prank(deployer);
        token.transfer(holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);

        string[22] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        address attacker = address(0xBEEF);
        for (uint256 i; i < sigs.length; ++i) {
            bytes memory data = abi.encodeWithSignature(sigs[i], holder, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, sigs[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(holder), held);

        // The deployer cannot pull from the holder either.
        vm.prank(deployer);
        (bool moved,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (holder, deployer, 1)));
        assertFalse(moved);
        assertEq(token.balanceOf(holder), held);

        // And the holder can still move.
        vm.prank(holder);
        assertTrue(token.transfer(alice, held / 2));
        assertEq(token.balanceOf(alice), held / 2);
    }

    /// @dev Mirrors the launch floor's opcode scan: no DELEGATECALL, CALLCODE or SELFDESTRUCT in the
    /// runtime, and the runtime fits EIP-170.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    /// @dev Metadata is identical across deployments and callers.
    function test_metadataDoesNotDependOnDeployerOrCaller() public {
        vm.prank(alice);
        RoboBetToken other = new RoboBetToken();
        vm.startPrank(bob);
        assertEq(other.name(), token.name());
        assertEq(other.symbol(), token.symbol());
        assertEq(other.decimals(), token.decimals());
        assertEq(other.totalSupply(), token.totalSupply());
        vm.stopPrank();
    }
}
