// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import '@openzeppelin/contracts/access/Ownable.sol';

contract CobToken is ERC20, Ownable {

    //////////////////////////////////////////////////////////////
    uint256 public constant maxSupply = 42000000 ether;
    //////////////////////////////////////////////////////////////

    constructor() public ERC20("CobToken", "COB") {}

    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);

        //////////////////////////////////////////////////////////////
        require(totalSupply() <= maxSupply, "COB: Max Supply Reached");
        //////////////////////////////////////////////////////////////
    }
}
