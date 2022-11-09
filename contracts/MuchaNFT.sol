// SPDX-License-Identifier: GPL

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Address.sol";

abstract contract MinterRole is Ownable {

    event SetMinterRole(address minter, bool status);
    
    mapping (address => bool) public minter_role;

    function setMinterRole(address _who, bool _status) public onlyOwner
    {
        minter_role[_who] = _status;

        emit SetMinterRole(_who, _status);
    }

    modifier onlyMinter
    {
        require(minter_role[msg.sender], "Minter role required");
        _;
    }
}

interface ICallistoNFT {

    event NewBid       (uint256 indexed tokenID, uint256 indexed bidAmount, bytes bidData);
    event TokenTrade   (uint256 indexed tokenID, address indexed new_owner, address indexed previous_owner, uint256 priceInWEI);
    event Transfer     (address indexed from, address indexed to, uint256 indexed tokenId);
    event TransferData (bytes data);
    
    struct Properties {
        
        // In this example properties of the given NFT are stored
        // in a dynamically sized array of strings
        // properties can be re-defined for any specific info
        // that a particular NFT is intended to store.
        
        /* Properties could look like this:
        bytes   property1;
        bytes   property2;
        address property3;
        */
        
        string[] properties;
    }
    
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function standard() external view returns (string memory);
    function balanceOf(address _who) external view returns (uint256);
    function ownerOf(uint256 _tokenId) external view returns (address);
    function transfer(address _to, uint256 _tokenId, bytes calldata _data) external returns (bool);
    function silentTransfer(address _to, uint256 _tokenId) external returns (bool);
    
    function priceOf(uint256 _tokenId) external view returns (uint256);
    function bidOf(uint256 _tokenId) external view returns (uint256 price, address payable bidder, uint256 timestamp);
    function getTokenProperties(uint256 _tokenId) external view returns (Properties memory);
    
    function setBid(uint256 _tokenId, bytes calldata _data) payable external; // bid amount is defined by msg.value
    function setPrice(uint256 _tokenId, uint256 _amountInWEI, bytes calldata _data) external;
    function withdrawBid(uint256 _tokenId) external returns (bool);

    function getUserContent(uint256 _tokenId) external view returns (string memory _content);
    function setUserContent(uint256 _tokenId, string calldata _content) external returns (bool);
}

abstract contract NFTReceiver {
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data) external virtual returns(bytes4);
}

// ExtendedNFT is a version of the CallistoNFT standard token
// that implements a set of function for NFT content management
abstract contract ExtendedNFT is ICallistoNFT, ReentrancyGuard {
    using Strings for string;
    using Address for address;
    
    mapping (uint256 => Properties) private _tokenProperties;
    mapping (uint32 => Fee)         public feeLevels; // level # => (fee receiver, fee percentage)
    
    uint256 public bidLock = 1 days; // Time required for a bid to become withdrawable.
    
    struct Bid {
        address payable bidder;
        uint256 amountInWEI;
        uint256 timestamp;
    }
    
    struct Fee {
        address payable feeReceiver;
        uint256 feePercentage; // Will be divided by 100000 during calculations
                               // feePercentage of 100 means 0.1% fee
                               // feePercentage of 2500 means 2.5% fee
    }
    
    mapping (uint256 => uint256) private _asks; // tokenID => price of this token (in WEI)
    mapping (uint256 => Bid)     private _bids; // tokenID => price of this token (in WEI)
    mapping (uint256 => uint32)  internal _tokenFeeLevels; // tokenID => level ID / 0 by default

    uint256 public next_mint_id;

    // Token name
    string internal _name;

    // Token symbol
    string internal _symbol;

    // Mapping from token ID to owner address
    mapping(uint256 => address) internal _owners;

    // Mapping owner address to token count
    mapping(address => uint256) internal _balances;
    

    // Reward is always paid based on BID
    modifier checkTrade(uint256 _tokenId, bytes calldata _data)
    {
        _;
        (uint256 _bid, address payable _bidder,) = bidOf(_tokenId);
        if(priceOf(_tokenId) > 0 && priceOf(_tokenId) <= _bid)
        {
            uint256 _reward = _bid - _claimFee(_bid, _tokenId);

            emit TokenTrade(_tokenId, _bidder, ownerOf(_tokenId), _reward);

            address ownerOfToken = ownerOf(_tokenId);
            assembly {
                pop(call(gas(), ownerOfToken, _reward, 0, 0, 0, 0))
            }

            //bytes calldata _empty;
            delete _bids[_tokenId];
            delete _asks[_tokenId];
            _transfer(ownerOf(_tokenId), _bidder, _tokenId, _data);
        }
    }
    
    function standard() public pure override returns (string memory)
    {
        return "CallistoNFT";
    }

    function mint() internal returns (uint256 _mintedId)
    {
        _safeMint(msg.sender, next_mint_id);
        _mintedId = next_mint_id;
        unchecked {
            next_mint_id++;
        }
        

        _configureNFT(_mintedId);
    }
    
    function priceOf(uint256 _tokenId) public view override returns (uint256)
    {
        address owner = _owners[_tokenId];
        require(owner != address(0), "NFT: owner query for nonexistent token");
        return _asks[_tokenId];
    }
    
    function bidOf(uint256 _tokenId) public view override returns (uint256 price, address payable bidder, uint256 timestamp)
    {
        address owner = _owners[_tokenId];
        require(owner != address(0), "NFT: owner query for nonexistent token");
        return (_bids[_tokenId].amountInWEI, _bids[_tokenId].bidder, _bids[_tokenId].timestamp);
    }
    
    function getTokenProperties(uint256 _tokenId) public view override returns (Properties memory)
    {
        return _tokenProperties[_tokenId];
    }

    function getTokenProperty(uint256 _tokenId, uint256 _propertyId)  public view returns (string memory)
    {
        return _tokenProperties[_tokenId].properties[_propertyId];
    }

    function getUserContent(uint256 _tokenId) public view override returns (string memory _content)
    {
        return (_tokenProperties[_tokenId].properties[0]);
    }

    function setUserContent(uint256 _tokenId, string calldata _content) public override returns (bool success)
    {
        require(msg.sender == ownerOf(_tokenId), "NFT: only owner can change NFT content");
        _tokenProperties[_tokenId].properties[0] = _content;
        return true;
    }

    function _addPropertyWithContent(uint256 _tokenId, string calldata _content) internal
    {
        // Check permission criteria

        _tokenProperties[_tokenId].properties.push(_content);
    }

    function _modifyProperty(uint256 _tokenId, uint256 _propertyId, string calldata _content) internal
    {
        _tokenProperties[_tokenId].properties[_propertyId] = _content;
    }

    function _appendProperty(uint256 _tokenId, uint256 _propertyId, string calldata _content) internal
    {
        _tokenProperties[_tokenId].properties[_propertyId] = string.concat(_tokenProperties[_tokenId].properties[_propertyId],_content);
    }
    
    function balanceOf(address owner) public view override returns (uint256) {
        require(owner != address(0), "NFT: balance query for the zero address");
        return _balances[owner];
    }
    
    function ownerOf(uint256 tokenId) public view override returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "NFT: owner query for nonexistent token");
        return owner;
    }
    
    /* 
        Price == 0, "NFT not on sale"
        Price > 0, "NFT on sale"
    */
    function setPrice(uint256 _tokenId, uint256 _amountInWEI, bytes calldata _data) checkTrade(_tokenId, _data) public override nonReentrant {
        require(ownerOf(_tokenId) == msg.sender, "Setting asks is only allowed for owned NFTs!");
        _asks[_tokenId] = _amountInWEI;
    }
    
    function setBid(uint256 _tokenId, bytes calldata _data) payable checkTrade(_tokenId, _data) public override nonReentrant
    {
        (uint256 _previousBid, address payable _previousBidder, ) = bidOf(_tokenId);
        require(msg.value > _previousBid, "New bid must exceed the existing one");

        uint256 _bid;

        // Return previous bid if the current one exceeds it.
        if(_previousBid != 0)
        {
            assembly {
                pop(call(gas(), _previousBidder, _previousBid, 0, 0, 0, 0))
            }
        }
        // Refund overpaid amount if price is greater than 0
        if (priceOf(_tokenId) < msg.value && priceOf(_tokenId) > 0)
        {
            _bid = priceOf(_tokenId);
        }
        else
        {
            _bid = msg.value;
        }
        _bids[_tokenId].amountInWEI = _bid;
        _bids[_tokenId].bidder      = payable(msg.sender);
        _bids[_tokenId].timestamp   = block.timestamp;

        emit NewBid(_tokenId, _bid, _data);
        
        // Send back overpaid amount.
        // WARNING: Creates possibility for reentrancy.
        if (priceOf(_tokenId) < msg.value && priceOf(_tokenId) > 0)
        {
            uint overpaid = msg.value - priceOf(_tokenId);
            assembly {
                pop(call(gas(), origin(), overpaid, 0, 0, 0, 0))
            }
        }
    }
    
    function withdrawBid(uint256 _tokenId) public override nonReentrant returns (bool) 
    {
        (uint256 _bid, address payable _bidder, uint256 _timestamp) = bidOf(_tokenId);
        require(msg.sender == _bidder, "Can not withdraw someone elses bid");
        require(block.timestamp > _timestamp + bidLock, "Bid is time-locked");

        assembly {
            pop(call(gas(), _bidder, _bid, 0, 0, 0, 0))
        }

        delete _bids[_tokenId];
        return true;
    }
    
    function name() public view override returns (string memory) {
        return _name;
    }
    
    function symbol() public view override returns (string memory) {
        return _symbol;
    }
    
    function transfer(address _to, uint256 _tokenId, bytes memory _data) public override returns (bool)
    {
        _transfer(msg.sender, _to, _tokenId, _data);
        emit TransferData(_data);
        return true;
    }
    
    function silentTransfer(address _to, uint256 _tokenId) public override returns (bool)
    {
        require(ExtendedNFT.ownerOf(_tokenId) == msg.sender, "NFT: transfer of token that is not own");
        require(_to != address(0), "NFT: transfer to the zero address");
        
        _asks[_tokenId] = 0; // Zero out price on transfer
        
        // When a user transfers the NFT to another user
        // it does not automatically mean that the new owner
        // would like to sell this NFT at a price
        // specified by the previous owner.
        
        // However bids persist regardless of token transfers
        // because we assume that the bidder still wants to buy the NFT
        // no matter from whom.

        _beforeTokenTransfer(msg.sender, _to, _tokenId);

        _balances[msg.sender] -= 1;
        _balances[_to] += 1;
        _owners[_tokenId] = _to;

        emit Transfer(msg.sender, _to, _tokenId);
        return true;
    }
    
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }
    
    function _claimFee(uint256 _amountFrom, uint256 _tokenId) internal returns (uint256)
    {
        uint32 _level          = _tokenFeeLevels[_tokenId];
        address _feeReceiver   = feeLevels[_level].feeReceiver;
        uint256 _feePercentage = feeLevels[_level].feePercentage;
        
        uint256 _feeAmount = _amountFrom * _feePercentage / 100_000;
        assembly {
            pop(call(gas(), _feeReceiver, _feeAmount, 0, 0, 0, 0))
        }
        return _feeAmount;        
    }
    
    function _safeMint(
        address to,
        uint256 tokenId
    ) internal virtual {
        _mint(to, tokenId);
    }
    
    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "NFT: mint to the zero address");
        require(!_exists(tokenId), "NFT: token already minted");

        _beforeTokenTransfer(address(0), to, tokenId);

        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }
    
    function _burn(uint256 tokenId) internal {
        address owner = ExtendedNFT.ownerOf(tokenId);

        _beforeTokenTransfer(owner, address(0), tokenId);
        

        _balances[owner] -= 1;
        delete _owners[tokenId];

        emit Transfer(owner, address(0), tokenId);
    }
    
    function _transfer(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal {
        require(ExtendedNFT.ownerOf(tokenId) == from, "NFT: transfer of token that is not own");
        require(to != address(0), "NFT: transfer to the zero address");
        
        _asks[tokenId] = 0; // Zero out price on transfer
        
        // When a user transfers the NFT to another user
        // it does not automatically mean that the new owner
        // would like to sell this NFT at a price
        // specified by the previous owner.
        
        // However bids persist regardless of token transfers
        // because we assume that the bidder still wants to buy the NFT
        // no matter from whom.

        _beforeTokenTransfer(from, to, tokenId);

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        if(to.isContract())
        {
            NFTReceiver(to).onERC721Received(msg.sender, from, tokenId, data);
        }

        emit Transfer(from, to, tokenId);
    }
    
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual {}

    function _configureNFT(uint256 _tokenId) internal
    {
        if(_tokenProperties[_tokenId].properties.length == 0)
        {
            _tokenProperties[_tokenId].properties.push("");
        }
    }
}

interface IClassifiedNFT is ICallistoNFT {
    function setClassForTokenID(uint256 _tokenID, uint256 _tokenClass) external;
    function addNewTokenClass(uint32 _feeLevel, string memory _property) external;
    function addTokenClassProperties(uint256 _propertiesCount, uint256 classId) external;
    function modifyClassProperty(uint256 _classID, uint256 _propertyID, string memory _content) external;
    function getClassProperty(uint256 _classID, uint256 _propertyID) external view returns (string memory);
    function addClassProperty(uint256 _classID, string memory _content) external;
    function getClassProperties(uint256 _classID) external view returns (string[] memory);
    function getClassForTokenID(uint256 _tokenID) external view returns (uint256);
    function getClassPropertiesForTokenID(uint256 _tokenID) external view returns (string[] memory);
    function getClassPropertyForTokenID(uint256 _tokenID, uint256 _propertyID) external view returns (string memory);
    function mintWithClass(uint256 classId)  external  returns (uint256 _newTokenID);
    function appendClassProperty(uint256 _classID, uint256 _propertyID, string memory _content) external;
}

abstract contract ClassifiedNFT is MinterRole, ExtendedNFT, IClassifiedNFT {
    using Strings for string;

    mapping (uint256 => string[]) public class_properties;
    mapping (uint256 => uint32)   public class_feeLevel;
    mapping (uint256 => uint256)  public token_classes;

    uint256 public nextClassIndex = 0;

    modifier onlyExistingClasses(uint256 classId)
    {
        require(classId < nextClassIndex, "Queried class does not exist");
        _;
    }

    function setClassForTokenID(uint256 _tokenID, uint256 _tokenClass) public onlyOwner override
    {
        token_classes[_tokenID] = _tokenClass;
    }

    function addNewTokenClass(uint32 _feeLevel, string memory _property) public onlyOwner override
    {
        class_properties[nextClassIndex].push(_property);
        class_feeLevel[nextClassIndex] = _feeLevel; // Configures who will receive fees from this class of NFTs
                                                    // Zero sets fees to default address and percentage.
        nextClassIndex++;
    }

    function addTokenClassProperties(uint256 _propertiesCount, uint256 classId) public onlyOwner override
    {
        for (uint i = 0; i < _propertiesCount; i++)
        {
            class_properties[classId].push("");
        }
    }

    function modifyClassProperty(uint256 _classID, uint256 _propertyID, string memory _content) public onlyOwner onlyExistingClasses(_classID) override
    {
        class_properties[_classID][_propertyID] = _content;
    }

    function getClassProperty(uint256 _classID, uint256 _propertyID) public view onlyExistingClasses(_classID) override returns (string memory)
    {
        return class_properties[_classID][_propertyID];
    }

    function addClassProperty(uint256 _classID, string memory _content) public onlyOwner onlyExistingClasses(_classID)
    {
        class_properties[_classID].push(_content);
    }

    function getClassProperties(uint256 _classID) public view onlyExistingClasses(_classID) override returns (string[] memory)
    {
        return class_properties[_classID];
    }

    function getClassForTokenID(uint256 _tokenID) public view onlyExistingClasses(token_classes[_tokenID]) override returns (uint256)
    {
        return token_classes[_tokenID];
    }

    function getClassPropertiesForTokenID(uint256 _tokenID) public view onlyExistingClasses(token_classes[_tokenID]) override returns (string[] memory)
    {
        return class_properties[token_classes[_tokenID]];
    }

    function getClassPropertyForTokenID(uint256 _tokenID, uint256 _propertyID) public view onlyExistingClasses(token_classes[_tokenID]) override returns (string memory)
    {
        return class_properties[token_classes[_tokenID]][_propertyID];
    }
    
    function mintWithClass(uint256 classId)  public onlyExistingClasses(classId) onlyMinter override returns (uint256 _newTokenID)
    {
        //_mint(to, tokenId);
        _newTokenID = mint();
        token_classes[_newTokenID] = classId;
        _tokenFeeLevels[_newTokenID] = class_feeLevel[classId];
    }

    function appendClassProperty(uint256 _classID, uint256 _propertyID, string memory _content) public onlyOwner onlyExistingClasses(_classID) override
    {
        class_properties[_classID][_propertyID] = string.concat(class_properties[_classID][_propertyID], _content);
    }
}

contract MuchaNFT is ExtendedNFT, ClassifiedNFT {

    function initialize(string memory name_, string memory symbol_, uint256 _defaultFee) external {
        require(owner() == address(0), "Already initialized");
        transferOwnership(msg.sender);
        bidLock = 1 days;
        _name   = name_;
        _symbol = symbol_;
        feeLevels[0].feeReceiver   = payable(msg.sender);
        feeLevels[0].feePercentage = _defaultFee;
    }

    function setFeeLevel(uint32 _levelIndex, address _feeReceiver, uint256 _feePercentage) public onlyOwner
    {
        feeLevels[_levelIndex].feeReceiver = payable(_feeReceiver);
        feeLevels[_levelIndex].feePercentage = _feePercentage;
    }

    function setFeeLevelForToken(uint256 _tokenId, uint32 _feeLevel) public onlyOwner
    {
        _tokenFeeLevels[_tokenId] = _feeLevel;
    }

    function modifyClassFeeLevel(uint256 _classId, uint32 _feeLevel) public onlyOwner
    {
        class_feeLevel[_classId] = _feeLevel;
    }

    /* onlyOwner or Minter */
    function addPropertyWithContent(uint256 _tokenId, string calldata _content) public 
    {
        require(owner() == msg.sender || minter_role[msg.sender], "Ownable: caller is not the owner");
        _addPropertyWithContent( _tokenId, _content);
    }

    function modifyProperty(uint256 _tokenId, uint256 _propertyId, string calldata _content) public onlyOwner
    {
        _modifyProperty(_tokenId, _propertyId, _content);
    }

    function appendProperty(uint256 _tokenId, uint256 _propertyId, string calldata _content) public onlyOwner
    {
        _appendProperty(_tokenId, _propertyId, _content);
    }

    function tokenURI(uint256 _tokenID) public view onlyExistingClasses(token_classes[_tokenID]) returns (string memory)
    {
        //Consider that the first (0) property has the same info that a JSON
        return class_properties[token_classes[_tokenID]][0];
    }
}