// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MiNFT is ERC721, ERC721URIStorage, Ownable {
    uint256 private tokenCounter;

    constructor() ERC721("MiNFT", "MNFT") Ownable(msg.sender) {
        tokenCounter = 0;
    }

    function mintNFT(address to, string memory ipfsMetadataURI) public onlyOwner {
        uint256 tokenId = tokenCounter;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, ipfsMetadataURI);
        tokenCounter++;
    }

    function _baseURI() internal pure override returns (string memory) {
        return "ipfs://";
    }

      function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}