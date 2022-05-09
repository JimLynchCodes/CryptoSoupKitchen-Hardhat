// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;
import "hardhat/console.sol";
import "./2_Owner.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

contract CryptoSoupKitchen is VRFConsumerBase {
    // owner who deployed this contract (Jim)
    address owner = msg.sender;

    // addresses of NFT contracts
    address[] nft_collections;

    uint256[][] nft_token_Ids_to_give_away;

    // each new collection added gets an index, enumerated from 0
    uint256 nft_collections_next_index;

    // running total of number of tokens left to give away across all collections
    uint256 total_num_of_nft_tokens_to_give_away;

    // keeps track of collections that have had tokends added before
    mapping(address => bool) nft_address_seen_before;

    // keeps track of index in 'nft_collections' to give away
    mapping(address => uint256) nft_indices;

    // keeps track of chainlink requests to match up in the randomnes callback
    mapping(bytes32 => address) requestsForSoup;

    // keeps track of payments made by users that have not been "processed" or withdrawn
    mapping(address => uint256) unfulfilledSoupPayments;

    // indexed same as nft_collections, keeps track of number of tokens left in contract to give away
    uint256[] nft_num_of_token_ids_to_give_away;

    // emitted when user asks for soup.
    event AskedForSoup(address requrestedBy);

    // jackpot stuff
    uint256 jackpot_starting_amount = 1 ether;
    uint256 jackpot = jackpot_starting_amount;
    uint256 chance_of_winning_jackpot = 50000;
    event JackpotWinner(address requestedBy, uint256 jackpot);

    // other constants
    uint256 soup_price = 0.1 ether;

    // chainlink VRF things
    bytes32 public keyHash;
    uint256 public fee;
    uint256 public randomResult;
    address mainnetLinkAddress = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    address testnetLinkAddress = 0x326C977E6efc84E512bB9C30f76E30c160eD06FB;
    address mainnetVrfCoordinator = 0x3d2341ADb2D31f1c5530cDC622016af293177AE0;
    address testnetVrfCoordinator = 0x8C7382F9D8f56b33781fE506E897a4F1e2d17255;
    bytes32 mainnetOracleKeyHash =
        0xf86195cf7690c55907b2b611ebb7343a6f649bff128701cc542f0569e2c549da;
    bytes32 testnetOracleKeyHash =
        0x6e75b569a01ef56d18cab6a8e71e6600d6ce853834d4a5748b720d06f878b3a4;
    uint256 MUMBAI_TESTNET_CHAINID = 80001;
    // address __linkTokenAddress = getChainId() == MUMBAI_TESTNET_CHAINID ? testnetLinkAddress : mainnetLinkAddress; // address __vrfCoordinatorAddress = getChainId() == MUMBAI_TESTNET_CHAINID ? testnetVrfCoordinator : mainnetVrfCoordinator; // bytes32 __oracleKeyhash = getChainId() == MUMBAI_TESTNET_CHAINID ? testnetOracleKeyHash : mainnetOracleKeyHash;
    address __linkTokenAddress = testnetLinkAddress;
    address __vrfCoordinatorAddress = testnetVrfCoordinator;
    bytes32 __oracleKeyhash = testnetOracleKeyHash;

    constructor() VRFConsumerBase(__vrfCoordinatorAddress, __linkTokenAddress) {
        keyHash = __oracleKeyhash;
        fee = 0.0001 * 10**18; // 0.0001 Link
    }

    function toAsciiString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2**(8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 * i] = char(hi);
            s[2 * i + 1] = char(lo);
        }
        return string(s);
    }

    function char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    function storeTokenIdsToGiveAwayForNft(
        address nft_address,
        uint256[] calldata token_ids
    ) external // onlyOwner
    {
        // Make sure contract is the owner of ALL token_ids passed in.

        // WARNING: Unbounded loop in Solidity is kind of an anti-pattern
        for (uint256 i = 0; i < token_ids.length; i++) {
            address token_owner = ERC721(nft_address).ownerOf(token_ids[i]);
            require(token_owner == address(this), toAsciiString(token_owner));
            // require(token_owner == address(this),  string(abi.encodePacked("Please transfer token ", token_ids[i], " to this contract:  ", address(this))));
        }

        if (!nft_address_seen_before[nft_address]) {
            console.log("new token!");

            nft_indices[nft_address] = nft_collections_next_index;

            nft_collections[nft_collections_next_index] = nft_address;

            nft_token_Ids_to_give_away[nft_collections_next_index] = token_ids;

            nft_num_of_token_ids_to_give_away[
                nft_collections_next_index
            ] = token_ids.length;

            total_num_of_nft_tokens_to_give_away += token_ids.length;

            nft_address_seen_before[nft_address] = true;

            nft_collections_next_index++;
        } else {
            uint256 nft_index = nft_indices[nft_address];
            total_num_of_nft_tokens_to_give_away -= nft_num_of_token_ids_to_give_away[
                nft_index
            ];
            total_num_of_nft_tokens_to_give_away += token_ids.length;
            nft_token_Ids_to_give_away[nft_index] = token_ids;
            nft_num_of_token_ids_to_give_away[nft_index] = token_ids.length;
        }
    }

    modifier paidOne() {
        require(
            msg.value == soup_price,
            "Please send one token with your request for soup!"
        );
        _;
    }

    function askForSoup() external payable paidOne {
        emit AskedForSoup(msg.sender);
        unfulfilledSoupPayments[msg.sender] += msg.value;
        bytes32 _requestId = requestRandomness(keyHash, fee);
        requestsForSoup[_requestId] = msg.sender;
        jackpot += msg.value / 10;
    }

    function fulfillRandomness(bytes32 requestId, uint256 randomness)
        internal
        override
    {
        address requestedBy = requestsForSoup[requestId];

        bool isJackpotWinner = randomness % chance_of_winning_jackpot == 1;

        if (isJackpotWinner) {
            emit JackpotWinner(requestedBy, jackpot);

            (bool success, ) = payable(requestedBy).call{value: (jackpot)}("");
            require(success);

            jackpot = jackpot_starting_amount;
        } else {
            uint256 randomlyChosenNftTokenIndex = (randomness %
                total_num_of_nft_tokens_to_give_away) + 1;

            uint256 tokenCount;

            for (uint256 i = 0; i < nft_collections_next_index; i++) {
                tokenCount += nft_num_of_token_ids_to_give_away[i];

                if (tokenCount >= randomlyChosenNftTokenIndex) {
                    address nftAddress = nft_collections[i];

                    uint256 tokenIndex = (randomness %
                        nft_num_of_token_ids_to_give_away[i]) + 1;

                    // transfer nft
                    uint256 tokenId = nft_token_Ids_to_give_away[i][tokenIndex];

                    ERC721(nftAddress).transferFrom(
                        address(this),
                        requestedBy,
                        tokenId
                    );

                    // remove tokenID from array (swap n' pop)

                    uint256 oldLastTokenIdValue = nft_token_Ids_to_give_away[i][
                        nft_num_of_token_ids_to_give_away[i]
                    ];

                    nft_token_Ids_to_give_away[i][
                        tokenIndex
                    ] = oldLastTokenIdValue;

                    nft_token_Ids_to_give_away[i].pop();

                    nft_num_of_token_ids_to_give_away[i]--;
                }
            }
        }
    }

    function getCurrentJackpotAmount() external view returns (uint256) {
        return jackpot;
    }

    function getNftCollectionAtIndex(uint256 index)
        external
        view
        returns (address)
    {
        return nft_collections[index];
    }

    // transfers an NFT owned by contract back to the sender
    function withdrawNft(address nftAddress, uint256 tokenId)
        external
    // onlyOwner
    {
        ERC721(nftAddress).transferFrom(address(this), msg.sender, tokenId);
    }

    // Withdraws only MATIC in excess of jackpot amount
    function withdrawNativeTokenProfits() external // onlyOwner
    {
        if (jackpot > address(this).balance) {
            revert("not enough MATIC to pay jackpot winner!");
        } else {
            (bool success, ) = payable(msg.sender).call{
                value: (address(this).balance - jackpot)
            }("");
            require(success);
        }
    }

    function withdraw_all_native_token() public payable // onlyOwner
    {
        (bool success, ) = payable(msg.sender).call{
            value: address(this).balance
        }("");
        require(success);
    }

    function withdrawLink() external // onlyOwner
    {
        ERC20(__linkTokenAddress).transfer(
            owner,
            ERC20(__linkTokenAddress).balanceOf(address(this))
        );
    }
}