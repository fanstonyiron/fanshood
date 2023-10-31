// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract FanshoodV1 is Ownable {
    address public protocolFeeDestination;
    uint256 public protocolFeePercent;
    uint256 public subjectFeePercent;
    address public fanshoodService;
    address public fanshoodAirdrop;
    address public fanshoodFinancial;
    uint256 public maxPreAmount = 1;

    struct BookOption {
        bool isBook;
        uint256 bookTime;
        uint256 openTime;
        bytes32 whitelistRoot;
    }

    event Trade(address trader, address subject, bool isBuy, uint256 hoodAmount, uint256 ethAmount, uint256 protocolEthAmount, uint256 subjectEthAmount, uint256 supply, uint256 tradeTime);

    event PreReleaseTrade(address subject, uint256 bookTime, uint256 openTime, uint256 tradeTime);

    event Pump(address subject, uint256 pumpAmount, uint256 totalPumpAmount);

    mapping(address => mapping(address => uint256)) public hoodsBalance;

    mapping(address => BookOption) public bookHoods;

    mapping(address => uint256) public  subjectPump;

    mapping(address => uint256) public  subjectIndex;

    mapping(address => uint256) public hoodsSupply;

    constructor(address _fanshoodService, address _fanshoodFinancial, address _fanshoodAirdrop) Ownable(msg.sender){
        protocolFeePercent = 50000000000000000;
        subjectFeePercent = 50000000000000000;
        fanshoodService = _fanshoodService;
        fanshoodFinancial = _fanshoodFinancial;
        fanshoodAirdrop = _fanshoodAirdrop;
    }

    function setFeeDestination(address _feeDestination) public onlyOwner {
        protocolFeeDestination = _feeDestination;
    }

    function setProtocolFeePercent(uint256 _feePercent) public onlyOwner {
        protocolFeePercent = _feePercent;
    }

    function setSubjectFeePercent(uint256 _feePercent) public onlyOwner {
        subjectFeePercent = _feePercent;
    }

    function getPrice(uint256 supply, uint256 amount, uint256 index) public pure returns (uint256) {
        uint256 sum1 = supply == 0 ? 0 : (supply - 1) * (supply) * (2 * (supply - 1) + 1) / 6;
        uint256 sum2 = supply == 0 && amount == 1 ? 0 : (supply - 1 + amount) * (supply + amount) * (2 * (supply - 1 + amount) + 1) / 6;
        uint256 summation = sum2 - sum1;
        return summation * 1 ether * 1e18 / index;
    }

    function getIndex(address hoodsSubject) public view returns (uint256)  {
        return subjectIndex[hoodsSubject] == 0 ? 16000 * 1e18 : subjectIndex[hoodsSubject];
    }

    function getBuyPrice(address hoodsSubject, uint256 amount) public view returns (uint256) {
        return getPrice(hoodsSupply[hoodsSubject], amount, getIndex(hoodsSubject));
    }

    function getSellPrice(address hoodsSubject, uint256 amount) public view returns (uint256) {
        return getPrice(hoodsSupply[hoodsSubject] - amount, amount, getIndex(hoodsSubject));
    }

    function getBuyPriceAfterFee(address hoodsSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(hoodsSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        return price + protocolFee + subjectFee;
    }

    function getSellPriceAfterFee(address hoodsSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(hoodsSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        return price - protocolFee - subjectFee;
    }

    function buyHoods(address hoodsSubject, uint256 amount) public payable {
        uint256 supply = hoodsSupply[hoodsSubject];
        require(supply > 0 || hoodsSubject == msg.sender, "Only the hoods' subject can buy the first hood");
        require(supply > 0 || amount == 1, "Only buy one for the first time");
        BookOption memory bookhood = bookHoods[hoodsSubject];
        require(!bookhood.isBook || block.timestamp > bookhood.openTime, "It is before the date on which we plan to presell hood, you can purchase it later.");
        uint256 price = getPrice(supply, amount, getIndex(hoodsSubject));
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        require(msg.value >= price + protocolFee + subjectFee, "Insufficient payment");
        hoodsBalance[hoodsSubject][msg.sender] = hoodsBalance[hoodsSubject][msg.sender] + amount;
        hoodsSupply[hoodsSubject] = supply + amount;
        emit Trade(msg.sender, hoodsSubject, true, amount, price, protocolFee, subjectFee, supply + amount, block.timestamp);
        (bool success1,) = protocolFeeDestination.call{value: protocolFee}("");
        (bool success2,) = hoodsSubject.call{value: subjectFee}("");
        require(success1 && success2, "Unable to send funds");
    }

    function airdropByFanshood(address hoodsSubject, address[] calldata _addresses) public payable {
        require(msg.sender == fanshoodAirdrop, "Bad call");
        uint256 supply = hoodsSupply[hoodsSubject];
        BookOption memory bookhood = bookHoods[hoodsSubject];
        require(supply > 0 && bookhood.isBook, "The hood creator has not presold hood");
        require(block.timestamp > bookhood.bookTime && block.timestamp < bookhood.openTime, "It is not within presell period");
        require(_addresses.length > 0, "Has not set whitelist");
        uint256 payment = getBuyPriceAfterFee(hoodsSubject, _addresses.length);
        require(msg.value >= payment, "Insufficient payment");
        uint256 amount = msg.value;
        for (uint64 i; i < _addresses.length; i++) {
            address _receiver = _addresses[i];
            supply = hoodsSupply[hoodsSubject];
            uint256 price = getPrice(supply, 1, getIndex(hoodsSubject));
            uint256 protocolFee = price * protocolFeePercent / 1 ether;
            uint256 subjectFee = price * subjectFeePercent / 1 ether;
            uint256 fee = price + protocolFee + subjectFee;
            require(amount >= fee, "Insufficient payment");
            hoodsBalance[hoodsSubject][_receiver] = hoodsBalance[hoodsSubject][_receiver] + 1;
            hoodsSupply[hoodsSubject] = supply + 1;
            emit Trade(_receiver, hoodsSubject, true, 1, price, protocolFee, subjectFee, supply + 1, block.timestamp);
            (bool success1,) = protocolFeeDestination.call{value: protocolFee}("");
            (bool success2,) = hoodsSubject.call{value: subjectFee}("");
            require(success1 && success2, "Unable to send funds");
            amount = amount - fee;
        }
    }

    function airdrop(address hoodsSubject, uint256 amount, bytes32[] calldata _proof) public payable {
        uint256 supply = hoodsSupply[hoodsSubject];
        BookOption memory bookhood = bookHoods[hoodsSubject];
        require(supply > 0 && bookhood.isBook, "The hood creator has not presold hood");
        require(block.timestamp > bookhood.bookTime && block.timestamp < bookhood.openTime, "It is not within presell period");
        require(bookhood.whitelistRoot != bytes32(0), "Has not set whitelist");
        bytes32 _leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verify(_proof, bookhood.whitelistRoot, _leaf), "Not in the whitelist");
        require(hoodsBalance[hoodsSubject][msg.sender] + amount <= maxPreAmount, "It has been exceeded the maximum number of hoods which are sold in advance");

        uint256 price = getPrice(supply, amount, getIndex(hoodsSubject));
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        require(msg.value >= price + protocolFee + subjectFee, "Insufficient payment");
        hoodsBalance[hoodsSubject][msg.sender] = hoodsBalance[hoodsSubject][msg.sender] + amount;
        uint256 total = supply + amount;
        hoodsSupply[hoodsSubject] = total;
        emit Trade(msg.sender, hoodsSubject, true, amount, price, protocolFee, subjectFee, total, block.timestamp);
        (bool success1,) = protocolFeeDestination.call{value: protocolFee}("");
        (bool success2,) = hoodsSubject.call{value: subjectFee}("");
        require(success1 && success2, "Unable to send funds");
    }

    function preRelease(uint256 bookTime, uint256 openTime, bytes32 whitelistRoot) public payable {
        require(tx.origin == msg.sender, "Only support EOA");
        require(bookTime > block.timestamp && openTime > block.timestamp && openTime > bookTime, "The time to begin presell hood is invalid");
        require(hoodsSupply[msg.sender] == 0 && !bookHoods[msg.sender].isBook, "Has already preselled hood");
        hoodsBalance[msg.sender][msg.sender] = 1;
        hoodsSupply[msg.sender] = 1;
        BookOption memory bookOption = BookOption({
            isBook: true,
            bookTime: bookTime,
            openTime: openTime,
            whitelistRoot: whitelistRoot
        });
        bookHoods[msg.sender] = bookOption;
        emit Trade(msg.sender, msg.sender, true, 1, 0, 0, 0, 1, block.timestamp);
        emit PreReleaseTrade(msg.sender, bookTime, openTime, block.timestamp);
    }

    function sellHoods(address hoodsSubject, uint256 amount) public payable {
        uint256 supply = hoodsSupply[hoodsSubject];
        require(supply > amount, "Cannot sell the last hood");
        BookOption memory bookhood = bookHoods[hoodsSubject];
        require(!bookhood.isBook || block.timestamp > bookhood.openTime, "Cannot be sold during the pre release period");
        uint256 price = getPrice(supply - amount, amount, getIndex(hoodsSubject));
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        require(hoodsBalance[hoodsSubject][msg.sender] >= amount, "Insufficient hoods");
        hoodsBalance[hoodsSubject][msg.sender] = hoodsBalance[hoodsSubject][msg.sender] - amount;
        hoodsSupply[hoodsSubject] = supply - amount;
        emit Trade(msg.sender, hoodsSubject, false, amount, price, protocolFee, subjectFee, supply - amount, block.timestamp);
        (bool success1,) = msg.sender.call{value: price - protocolFee - subjectFee}("");
        (bool success2,) = protocolFeeDestination.call{value: protocolFee}("");
        (bool success3,) = hoodsSubject.call{value: subjectFee}("");
        require(success1 && success2 && success3, "Unable to send funds");
    }

    function pump(address hoodsSubject) public payable {
        require(msg.sender == fanshoodFinancial, "Bad call");
        uint256 supply = hoodsSupply[hoodsSubject];
        require(supply > 1, "Hood supply must more than 1");
        require(msg.value > 0.001 ether, "pump amount invalid");
        BookOption memory bookhood = bookHoods[hoodsSubject];
        require(!bookhood.isBook || block.timestamp > bookhood.openTime, "Cannot pump amount during the pre-release period");
        subjectPump[hoodsSubject] = subjectPump[hoodsSubject] + msg.value;
        uint256 sum = supply * (supply + 1) * (2 * supply + 1) / 6;
        uint256 amount = sum * 1 ether / 16000;
        uint256 index = (16000 * amount * 1e18) / (amount + subjectPump[hoodsSubject]);
        subjectIndex[hoodsSubject] = index;
        emit Pump(hoodsSubject, msg.value, subjectPump[hoodsSubject]);
    }

    function updateWhiteList(address hoodsSubject, bytes32 whitelistRoot) external {
        require(tx.origin == msg.sender && msg.sender == fanshoodService, "Bad call");
        require(whitelistRoot != bytes32(0), "whitelist root is empty");
        BookOption storage bookhood = bookHoods[hoodsSubject];
        require(bookhood.isBook, "No pre-release");
        require(block.timestamp < bookhood.bookTime, "Already pre-sold");
        bookhood.whitelistRoot = whitelistRoot;
        bookHoods[hoodsSubject] = bookhood;
    }

    function setFanshoodService(address _fanshoodService) public onlyOwner {
        fanshoodService = _fanshoodService;
    }

    function setFanshoodAirdrop(address _fanshoodAirdrop) public onlyOwner {
        fanshoodAirdrop = _fanshoodAirdrop;
    }

    function setFanshoodFinancial(address _fanshoodFinancial) public onlyOwner {
        fanshoodFinancial = _fanshoodFinancial;
    }

    function setMaxPreAmount(uint256 _amount) public onlyOwner {
        maxPreAmount = _amount;
    }
}
