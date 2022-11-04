// SPDX-License-Identifier: GPL

pragma solidity ^0.8.0;

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address internal _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
    constructor() {
        _transferOwnership(_msgSender());
    }
    */

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    /*
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }
    */
    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

interface NFTInterface {
    function mintWithClass(uint256 classId) external returns (uint256 _newTokenID);
    function transfer(address _to, uint256 _tokenId, bytes calldata _data) external returns (bool);
    function addPropertyWithContent(uint256 _tokenId, string calldata _content) external;
}

contract NFTMulticlassFreeMint is Ownable{

    event ClassMinterCreated(uint256 indexed tokenClassAuctionID);
    event TokenMinted(uint256 indexed tokenID, uint256 indexed tokenClassID, address indexed beneficiary);
    event NFTContractSet(address indexed newNFTContract, address indexed oldNFTContract);
 
    address public nft_contract;

    struct NFTClassMinter
    {
        uint256 amount_minted;
        mapping (address => bool) isOwner;
    }

    mapping (uint256 => NFTClassMinter) public classMinters; // Mapping from classID (at NFT contract) to set of variables
                                                             //  defining the auction for this token class.

    constructor()
    {
        _owner = msg.sender;
    }

    function createNFTClassMinter(uint256 _classID) public onlyOwner
    {
        classMinters[_classID].amount_minted = 0; 

        emit ClassMinterCreated(_classID);
    }

    function setNFTContract(address _nftContract) public onlyOwner
    {
        emit NFTContractSet(_nftContract, nft_contract);

        nft_contract = _nftContract;
    }

    function getIsOwner(uint _classID, address _address) public view returns (bool) {
        return classMinters[_classID].isOwner[_address];
    }

    function mintNFT(uint256 _classID, address _to) public onlyOwner
    {
        require(classMinters[_classID].isOwner[_to] == false, "Token already minted to this address");
        uint256 _mintedId = NFTInterface(nft_contract).mintWithClass(_classID);
        classMinters[_classID].amount_minted++;
        configureNFT(_mintedId, _classID);
        classMinters[_classID].isOwner[_to] = true;
        NFTInterface(nft_contract).transfer(_to, _mintedId, "");

        emit TokenMinted(_mintedId, _classID, msg.sender);
    }

    function configureNFT(uint256 _tokenId, uint256 _classId) internal
    {
        //Add Serial Number to the created Token
        uint256 tokenSerialNumber = classMinters[_classId].amount_minted;
        NFTInterface(nft_contract).addPropertyWithContent(_tokenId, toString(tokenSerialNumber));
    }

    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Strings.sol#L15-L35

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}