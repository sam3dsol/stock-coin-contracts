// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFactoryBase} from "./LaunchFactoryBase.sol";
import {ProbeHoursToken} from "./ProbeHoursToken.sol";

/// @title  Probe Factory
/// @notice Launches the REHEARSAL token only: five minutes open, five minutes
///         shut. It has no code path that can deploy the flagship, so a drill
///         can never touch the real launch, whatever anyone types.
contract ProbeFactory is LaunchFactoryBase {
    constructor(address _positionManager, address _router, address _weth, uint24 _poolFee, int24 _tickSpacing)
        LaunchFactoryBase(_positionManager, _router, _weth, _poolFee, _tickSpacing)
    {}

    function _deployToken(bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        internal
        override
        returns (address)
    {
        return address(new ProbeHoursToken{salt: salt}(name, symbol, supply));
    }

    function tokenInitCode(string memory name, string memory symbol, uint256 supplyWei)
        public
        pure
        override
        returns (bytes memory)
    {
        return abi.encodePacked(type(ProbeHoursToken).creationCode, abi.encode(name, symbol, supplyWei));
    }
}
