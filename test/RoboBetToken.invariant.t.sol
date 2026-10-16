// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RoboBetToken} from "../src/RoboBetToken.sol";

/// @notice Drives the token with a fixed set of actors in random order, with bounded inputs that
/// deliberately reach past each actor's balance and allowance so the revert paths are exercised as
/// often as the happy ones. Mirrors every balance and allowance in ghost storage so the invariants
/// compare the token against an independent ledger rather than against itself.
/// @dev Every call either succeeds and is recorded, or fails with the exact ERC-6093 error and is
/// checked to have changed nothing. The handler itself never reverts, so `fail_on_revert` can stay on
/// and a reverted call is a harness bug, not noise.
contract RoboBetHandler is CommonBase, StdCheats, StdUtils {
    RoboBetToken public immutable token;
    uint256 public immutable supply;

    // Actors: the factory (deployer), a stand-in distributor, a pool-manager-like contract address,
    // and ordinary holders. Index 0 is the factory and starts with the whole supply.
    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost ledger.
    mapping(address => uint256) public ghost_balance;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    uint256 public ghost_totalMoved; // sum of amounts successfully transferred
    uint256 public ghost_transfers; // successful transfer / transferFrom calls
    uint256 public ghost_revertsInsufficientBalance;
    uint256 public ghost_revertsInsufficientAllowance;
    uint256 public ghost_revertsInvalidReceiver;
    uint256 public ghost_adminAttempts;

    constructor(RoboBetToken token_, address factory_, address[] memory others) {
        token = token_;
        supply = token_.totalSupply();
        actors.push(factory_);
        isActor[factory_] = true;
        for (uint256 i; i < others.length; ++i) {
            actors.push(others[i]);
            isActor[others[i]] = true;
        }
        ghost_balance[factory_] = supply;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Amount drawn across [0, 2 * balance + 1] so that roughly half the draws overshoot.
    function _amountAround(uint256 seed, uint256 limit) internal pure returns (uint256) {
        return bound(seed, 0, 2 * limit + 1);
    }

    // ------------------------------------------------------------------------------------------
    // transfer
    // ------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 fromBal = token.balanceOf(from);
        uint256 toBal = token.balanceOf(to);
        uint256 amount = _amountAround(amountSeed, fromBal);

        vm.prank(from);
        if (amount > fromBal) {
            try token.transfer(to, amount) returns (bool) {
                revert("transfer above balance did not revert");
            } catch (bytes memory err) {
                _expectError(
                    err, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, fromBal, amount)
                );
                ghost_revertsInsufficientBalance++;
            }
            assert(token.balanceOf(from) == fromBal);
            assert(token.balanceOf(to) == toBal);
            return;
        }

        bool ok = token.transfer(to, amount);
        assert(ok);
        if (from == to) {
            assert(token.balanceOf(from) == fromBal);
        } else {
            assert(token.balanceOf(from) == fromBal - amount);
            assert(token.balanceOf(to) == toBal + amount);
            ghost_balance[from] -= amount;
            ghost_balance[to] += amount;
        }
        ghost_totalMoved += amount;
        ghost_transfers++;
    }

    /// @dev The zero address is never a valid receiver, whatever the amount and whoever sends.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 fromBal = token.balanceOf(from);
        vm.prank(from);
        try token.transfer(address(0), amount) returns (bool) {
            revert("transfer to zero address did not revert");
        } catch (bytes memory err) {
            _expectError(err, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            ghost_revertsInvalidReceiver++;
        }
        assert(token.balanceOf(from) == fromBal);
    }

    // ------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ------------------------------------------------------------------------------------------

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Mix in unbounded values so type(uint256).max (infinite allowance) is drawn regularly.
        if (amount % 7 == 0) amount = type(uint256).max;
        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assert(ok);
        assert(token.allowance(owner, spender) == amount);
        ghost_allowance[owner][spender] = amount;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) returns (bool) {
            revert("approve of zero spender did not revert");
        } catch (bytes memory err) {
            _expectError(err, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        assert(token.allowance(owner, address(0)) == 0);
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 ownerBal = token.balanceOf(owner);
        uint256 toBal = token.balanceOf(to);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = allowed == type(uint256).max ? ownerBal : (allowed < ownerBal ? allowed : ownerBal);
        uint256 amount = _amountAround(amountSeed, cap);

        vm.prank(spender);
        if (allowed != type(uint256).max && amount > allowed) {
            // Allowance is checked before balance in OZ v5.
            try token.transferFrom(owner, to, amount) returns (bool) {
                revert("transferFrom above allowance did not revert");
            } catch (bytes memory err) {
                _expectError(
                    err,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                );
                ghost_revertsInsufficientAllowance++;
            }
            _assertUnchanged(owner, ownerBal, to, toBal, spender, allowed);
            return;
        }
        if (amount > ownerBal) {
            try token.transferFrom(owner, to, amount) returns (bool) {
                revert("transferFrom above balance did not revert");
            } catch (bytes memory err) {
                _expectError(
                    err, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, ownerBal, amount)
                );
                ghost_revertsInsufficientBalance++;
            }
            _assertUnchanged(owner, ownerBal, to, toBal, spender, allowed);
            return;
        }

        bool ok = token.transferFrom(owner, to, amount);
        assert(ok);
        if (allowed == type(uint256).max) {
            assert(token.allowance(owner, spender) == type(uint256).max);
        } else {
            assert(token.allowance(owner, spender) == allowed - amount);
            ghost_allowance[owner][spender] = allowed - amount;
        }
        if (owner == to) {
            assert(token.balanceOf(owner) == ownerBal);
        } else {
            assert(token.balanceOf(owner) == ownerBal - amount);
            assert(token.balanceOf(to) == toBal + amount);
            ghost_balance[owner] -= amount;
            ghost_balance[to] += amount;
        }
        ghost_totalMoved += amount;
        ghost_transfers++;
    }

    /// @dev A spender with no allowance at all (the common "deployer pulls from a holder" attack) is
    /// refused even for a single minor unit.
    function transferFromWithoutAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        if (token.allowance(owner, spender) != 0) return; // not the case under test
        uint256 amount = bound(amountSeed, 1, supply);
        uint256 ownerBal = token.balanceOf(owner);
        vm.prank(spender);
        try token.transferFrom(owner, spender, amount) returns (bool) {
            revert("transferFrom with zero allowance did not revert");
        } catch (bytes memory err) {
            _expectError(
                err, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount)
            );
            ghost_revertsInsufficientAllowance++;
        }
        assert(token.balanceOf(owner) == ownerBal);
    }

    // ------------------------------------------------------------------------------------------
    // privileged / unknown calls
    // ------------------------------------------------------------------------------------------

    /// @dev Random selectors, including the usual admin ones, from random actors (the factory among
    /// them). None may exist; the invariants then check nothing moved.
    function callAdmin(uint256 callerSeed, uint256 which, uint256 arg) external {
        address caller = _actor(callerSeed);
        string[12] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "transferOwnership(address)",
            "setMinter(address)",
            "upgradeTo(address)"
        ];
        bytes memory data = abi.encodeWithSignature(sigs[bound(which, 0, sigs.length - 1)], caller, arg);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assert(!ok);
        ghost_adminAttempts++;
    }

    /// @dev The token has no receive or fallback; ETH sent to it must bounce.
    function sendEther(uint256 callerSeed, uint256 value) external {
        address caller = _actor(callerSeed);
        value = bound(value, 0, 100 ether);
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}("");
        assert(!ok);
        assert(address(token).balance == 0);
    }

    // ------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------

    function _assertUnchanged(
        address owner,
        uint256 ownerBal,
        address to,
        uint256 toBal,
        address spender,
        uint256 allowed
    ) internal view {
        assert(token.balanceOf(owner) == ownerBal);
        assert(token.balanceOf(to) == toBal);
        assert(token.allowance(owner, spender) == allowed);
    }

    function _expectError(bytes memory actual, bytes memory expected) internal pure {
        require(keccak256(actual) == keccak256(expected), "unexpected revert data");
    }
}

/// @notice A holder that is a contract, so the actor set includes code as well as EOAs.
contract ContractHolder {}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RoboBetTokenInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    RoboBetToken token;
    RoboBetHandler handler;
    address factory = address(0xFAC7);

    function setUp() public {
        vm.prank(factory);
        token = new RoboBetToken();

        address[] memory others = new address[](6);
        others[0] = address(0xD157); // distributor
        others[1] = address(0x900C); // pool-manager-like address
        others[2] = address(0xA11CE);
        others[3] = address(0xB0B);
        others[4] = address(0xCA201);
        others[5] = address(new ContractHolder());

        handler = new RoboBetHandler(token, factory, others);
        targetContract(address(handler));
    }

    /// @dev The fixed supply never changes, whatever sequence of calls anyone makes.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev Every unit minted sits with exactly one actor: the sum of actor balances is the supply.
    /// Only actors ever receive, so nothing can leak to an untracked address.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
    }

    /// @dev The token's balances agree with the independent ghost ledger for every actor.
    function invariant_balancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghost_balance(a));
            assertLe(token.balanceOf(a), SUPPLY);
        }
    }

    /// @dev Allowances agree with the ghost ledger for every (owner, spender) pair of actors.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender));
            }
        }
    }

    /// @dev Nothing is ever credited to the zero address or to the token itself, and the token
    /// never holds ETH.
    function invariant_noValueStrandedInZeroOrSelf() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(address(token).balance, 0);
    }

    /// @dev Metadata is immutable.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "ROBOBET");
        assertEq(token.symbol(), "ROBOBET");
        assertEq(token.decimals(), 18);
    }

    /// @dev The handler must reach both the happy and the failing paths, or the invariants above are
    /// vacuous. Driven deterministically here (a fixed pseudo-random sequence) so the coverage check
    /// cannot flake the way a per-sequence afterInvariant could.
    function test_handlerReachesEveryPath() public {
        uint256 seed = uint256(keccak256("ROBOBET handler coverage"));
        for (uint256 i; i < 400; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 a = uint256(keccak256(abi.encode(seed, "a")));
            uint256 b = uint256(keccak256(abi.encode(seed, "b")));
            uint256 c = uint256(keccak256(abi.encode(seed, "c")));
            uint256 d = uint256(keccak256(abi.encode(seed, "d")));
            uint256 which = seed % 8;
            if (which == 0) handler.transfer(a, b, c);
            else if (which == 1) handler.transferToZero(a, c);
            else if (which == 2) handler.approve(a, b, c);
            else if (which == 3) handler.approveZeroSpender(a, c);
            else if (which == 4) handler.transferFrom(a, b, c, d);
            else if (which == 5) handler.transferFromWithoutAllowance(a, b, c);
            else if (which == 6) handler.callAdmin(a, b, c);
            else handler.sendEther(a, c);
        }
        assertGt(handler.ghost_transfers(), 0, "no successful transfer was exercised");
        assertGt(handler.ghost_totalMoved(), 0, "no value moved");
        assertGt(handler.ghost_revertsInsufficientBalance(), 0, "insufficient-balance path not exercised");
        assertGt(handler.ghost_revertsInsufficientAllowance(), 0, "insufficient-allowance path not exercised");
        assertGt(handler.ghost_revertsInvalidReceiver(), 0, "zero-receiver path not exercised");
        assertGt(handler.ghost_adminAttempts(), 0, "admin selectors not exercised");
        // And the invariants hold at the end of the scripted sequence too.
        invariant_totalSupplyIsFixed();
        invariant_sumOfBalancesEqualsSupply();
        invariant_balancesMatchGhostLedger();
        invariant_allowancesMatchGhostLedger();
        invariant_noValueStrandedInZeroOrSelf();
    }
}
