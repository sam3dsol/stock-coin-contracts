// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFactoryBase} from "./LaunchFactoryBase.sol";
import {MarketHoursToken} from "./MarketHoursToken.sol";

/// @title  Stock Factory
/// @notice Launches the FLAGSHIP $STOCK only: Monday to Friday, 09:30 to 16:00
///         New York. It has no code path that can deploy the rehearsal token,
///         so the drill and the real launch cannot be confused for each other.
contract StockFactory is LaunchFactoryBase {
    constructor(address _positionManager, address _router, address _weth, uint24 _poolFee, int24 _tickSpacing)
        LaunchFactoryBase(_positionManager, _router, _weth, _poolFee, _tickSpacing)
    {}

    function _deployToken(bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        internal
        override
        returns (address)
    {
        return address(new MarketHoursToken{salt: salt}(name, symbol, supply));
    }

    function tokenInitCode(string memory name, string memory symbol, uint256 supplyWei)
        public
        pure
        override
        returns (bytes memory)
    {
        return abi.encodePacked(type(MarketHoursToken).creationCode, abi.encode(name, symbol, supplyWei));
    }
}
