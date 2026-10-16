// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ROBOBET
/// @notice Fixed-supply ERC-20. The whole supply of 1,000,000,000 ROBOBET (18 decimals) is minted
/// once, in the constructor, to the deployer (on launch: the IMD ProjectFactory).
/// @dev No owner, no mint, no burn, no pause, no blacklist, no transfer fee. Nothing can change the
/// supply or move a holder's balance after deployment except the holder (or an approved spender).
contract RoboBetToken is ERC20 {
    /// @notice The fixed total supply, in minor units (1e9 * 1e18).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("ROBOBET", "ROBOBET") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
