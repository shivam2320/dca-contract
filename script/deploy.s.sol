// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DCAProxyScript is Script {
    address router;
    address dcaImplementation;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes memory data = abi.encodeWithSignature(
            "initialize(address)",
            router
        );
        address dcaProxy = address(
            new TransparentUpgradeableProxy(dcaImplementation, msg.sender, data)
        );
        vm.startBroadcast(deployerPrivateKey);
        vm.stopBroadcast();
    }
}
