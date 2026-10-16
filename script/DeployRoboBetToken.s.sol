// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {RoboBetToken} from "../src/RoboBetToken.sol";

/// @notice Reviewable deployment of the token for local or test networks. The production launch is
/// performed by IMD's ProjectFactory from the attested bytecode; this script is not that launch.
/// @dev The token takes no constructor arguments and mints the whole supply to whoever deploys it.
contract DeployRoboBetToken is Script {
    function run() external returns (RoboBetToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }

    function deploy() public returns (RoboBetToken) {
        return new RoboBetToken();
    }
}
