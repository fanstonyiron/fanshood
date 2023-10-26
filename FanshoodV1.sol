// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {FanshoodData} from "./FanshoodData.sol";

contract FanshoodV1 is Ownable {
    using FanshoodData for FanshoodData.BookOption;
    address public protocolFeeDestination;//协议手续费收款地址
    uint256 public protocolFeePercent;//协议手续费百分比
    uint256 public subjectFeePercent;//发行方手续费百分比
    address public fanshoodAdmin;//平台管理员
    uint256 public maxPreAmount = 1;//预售白名单最大购买数量

    //交易Event事件
    //交易发起者地址,发行方地址,是否为购买行为,keys的数量,eth数量,协议收取eth数量,发行方收取eth数量,交易完成后总持有量
    event Trade(address trader, address subject, bool isBuy, uint256 hoodAmount, uint256 ethAmount, uint256 protocolEthAmount, uint256 subjectEthAmount, uint256 supply, uint256 tradeTime);
    event PreReleaseTrade(address subject, uint256 bookTime, uint256 openTime, bytes32 whitelistRoot, uint256 tradeTime);
    // hoodsSubject => (Holder => Balance)
    //每个发行合集的持有者账单=>(持有者=>持有数量)
    mapping(address => mapping(address => uint256)) public hoodsBalance;

    //预售发行合集
    mapping(address => FanshoodData.BookOption) public bookHoods;

    //发行人增值金额
    mapping(address => uint256) public  subjectPump;

    // hoodsSubject => Supply
    //每个发行合集的地址=>当前总持有量
    mapping(address => uint256) public hoodsSupply;

    constructor(address _fanshoodAdmin) Ownable(msg.sender){
        protocolFeePercent = 50000000000000000;
        subjectFeePercent = 50000000000000000;
        fanshoodAdmin = _fanshoodAdmin;
    }

    //设置协议手续费收款地址
    function setFeeDestination(address _feeDestination) public onlyOwner {
        protocolFeeDestination = _feeDestination;
    }

    //设置协议手续费百分比
    function setProtocolFeePercent(uint256 _feePercent) public onlyOwner {
        protocolFeePercent = _feePercent;
    }

    //设置发行方手续费百分比
    function setSubjectFeePercent(uint256 _feePercent) public onlyOwner {
        subjectFeePercent = _feePercent;
    }

    //根据每个发行合集的当前持有量,和要购买/售卖的数量计算得出最终需要购买花费/销售得到的金额(不包含手续费费)
    function getPrice(uint256 supply, uint256 amount) public pure returns (uint256) {
        uint256 sum1 = supply == 0 ? 0 : (supply - 1) * (supply) * (2 * (supply - 1) + 1) / 6;
        uint256 sum2 = supply == 0 && amount == 1 ? 0 : (supply - 1 + amount) * (supply + amount) * (2 * (supply - 1 + amount) + 1) / 6;
        uint256 summation = sum2 - sum1;
        return summation * 1 ether / 16000;
    }

    //发行方增值金额
    function getAppreciatePrice(address hoodsSubject) public view returns (uint256)  {
        uint256 supply = hoodsSupply[hoodsSubject];
        return (6 * supply * subjectPump[hoodsSubject]) / ((supply + 1) * (2 * supply + 1));
    }

    //计算购买价格(不含手续费)
    function getBuyPrice(address hoodsSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getPrice(hoodsSupply[hoodsSubject], amount);
        return price + getAppreciatePrice(hoodsSubject);
    }

    //计算售卖价格(不含手续费)
    function getSellPrice(address hoodsSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getPrice(hoodsSupply[hoodsSubject] - amount, amount);
        return price + getAppreciatePrice(hoodsSubject);
    }

    //计算包含手续费的购买价格
    function getBuyPriceAfterFee(address hoodsSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(hoodsSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        return price + protocolFee + subjectFee;
    }

    //计算扣除手续费后的售卖价格
    function getSellPriceAfterFee(address hoodsSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(hoodsSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        return price - protocolFee - subjectFee;
    }

    //购买hoods
    function buyHoods(address hoodsSubject, uint256 amount) public payable {
        uint256 supply = hoodsSupply[hoodsSubject];
        //每个发行合集的第一个keys只能发行方本人进行购买
        require(supply > 0 || hoodsSubject == msg.sender, "Only the hoods' subject can buy the first hood");
        require(supply > 0 || amount == 1, "Only buy one for the first time");
        //是否为预发售
        FanshoodData.BookOption memory bookhood = bookHoods[hoodsSubject];
        //预发售hood是否到了开放购买
        require(!bookhood.isBook || block.timestamp > bookhood.openTime, "Pre-release hood is not open buy");
        uint256 price = getPrice(supply, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        require(msg.value >= price + protocolFee + subjectFee, "Insufficient payment");
        hoodsBalance[hoodsSubject][msg.sender] = hoodsBalance[hoodsSubject][msg.sender] + amount;
        hoodsSupply[hoodsSubject] = supply + amount;
        emit Trade(msg.sender, hoodsSubject, true, amount, price, protocolFee, subjectFee, supply + amount, block.timestamp);
        //购买同样会产生交易手续费用
        (bool success1,) = protocolFeeDestination.call{value: protocolFee}("");
        (bool success2,) = hoodsSubject.call{value: subjectFee}("");
        require(success1 && success2, "Unable to send funds");
    }

    //预售
    function buyHoodsWithWihtelist(address hoodsSubject, uint256 amount, bytes32[] calldata _proof) public payable {
        require(tx.origin == msg.sender, "Only support EOA");
        uint256 supply = hoodsSupply[hoodsSubject];
        //每个发行合集的第一个keys只能发行方本人进行购买
        require(supply > 0 || hoodsSubject == msg.sender, "Only the hoods' subject can buy the first hood");
        require(supply > 0 || amount == 1, "Only buy one for the first time");
        FanshoodData.BookOption memory bookhood = bookHoods[hoodsSubject];
        //是否为预发售
        require(bookhood.isBook, "Hood is not pre-release");
        //是否在预售期间
        require(block.timestamp > bookhood.bookTime && block.timestamp < bookhood.openTime, "Pre-release time not reached");
        //是否设置了白名单
        require(bookhood.whitelistRoot != bytes32(0), "Not set whitelist");
        //是否在白名单内
        bytes32 _leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verify(_proof, bookhood.whitelistRoot, _leaf), "Not in the whitelist");
        //校验是否超过预售最大购买数量
        require(hoodsBalance[hoodsSubject][msg.sender] + amount <= maxPreAmount, "Purchase quantity exceeds the maximum quantity limit");

        uint256 price = getPrice(supply, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        require(msg.value >= price + protocolFee + subjectFee, "Insufficient payment");
        hoodsBalance[hoodsSubject][msg.sender] = hoodsBalance[hoodsSubject][msg.sender] + amount;
        uint256 total = supply + amount;
        hoodsSupply[hoodsSubject] = total;
        emit Trade(msg.sender, hoodsSubject, true, amount, price, protocolFee, subjectFee, total, block.timestamp);
        //购买同样会产生交易手续费用
        (bool success1,) = protocolFeeDestination.call{value: protocolFee}("");
        (bool success2,) = hoodsSubject.call{value: subjectFee}("");
        require(success1 && success2, "Unable to send funds");
    }

    //预发行
    //bookBlocks：预售开始购买时间，openBlocks：开放所有人购买时间，whitelistRoot：白名单账户
    function preRelease(uint256 bookTime, uint256 openTime, bytes32 whitelistRoot) external {
        require(tx.origin == msg.sender, "Only support EOA");
        //限制
        require(bookTime > block.timestamp && openTime > block.timestamp && openTime > bookTime, "Pre-release time or opening time invalid");
        require(hoodsSupply[msg.sender] == 0 && !bookHoods[msg.sender].isBook, "Already released hood");
        hoodsBalance[msg.sender][msg.sender] = 1;
        hoodsSupply[msg.sender] = 1;
        FanshoodData.BookOption memory bookOption = FanshoodData.BookOption({
            isBook: true,
            bookTime: bookTime,
            openTime: openTime,
            whitelistRoot: whitelistRoot
        });
        bookHoods[msg.sender] = bookOption;
        emit Trade(msg.sender, msg.sender, true, 1, 0, 0, 0, 1, block.timestamp);
        emit PreReleaseTrade(msg.sender, bookTime, openTime, whitelistRoot, block.timestamp);
    }

    //售卖keys
    function sellHoods(address hoodsSubject, uint256 amount) public payable {
        uint256 supply = hoodsSupply[hoodsSubject];
        //每个发行合集的最后一个keys不可进行售卖
        require(supply > amount, "Cannot sell the last hood");
        uint256 price = getPrice(supply - amount, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        require(hoodsBalance[hoodsSubject][msg.sender] >= amount, "Insufficient hoods");
        hoodsBalance[hoodsSubject][msg.sender] = hoodsBalance[hoodsSubject][msg.sender] - amount;
        hoodsSupply[hoodsSubject] = supply - amount;
        emit Trade(msg.sender, hoodsSubject, false, amount, price, protocolFee, subjectFee, supply - amount, block.timestamp);
        //售卖者得到的最终金额为扣除所有手续费后的金额
        (bool success1,) = msg.sender.call{value: price - protocolFee - subjectFee}("");
        (bool success2,) = protocolFeeDestination.call{value: protocolFee}("");
        (bool success3,) = hoodsSubject.call{value: subjectFee}("");
        require(success1 && success2 && success3, "Unable to send funds");
    }

    //修改白名单
    function updateWhiteList(address hoodsSubject, bytes32 whitelistRoot) external {
        require(tx.origin == msg.sender && msg.sender == fanshoodAdmin, "Bad call");
        require(whitelistRoot != bytes32(0), "whitelist root is empty");
        FanshoodData.BookOption storage bookhood = bookHoods[hoodsSubject];
        require(bookhood.isBook, "No pre-release");
        require(block.timestamp < bookhood.bookTime, "Already pre-sold");
        bookhood.whitelistRoot = whitelistRoot;
        bookHoods[hoodsSubject] = bookhood;
    }

    //注入资金
    function pump(address hoodsSubject) public payable {
        require(tx.origin == msg.sender && msg.sender == fanshoodAdmin, "Bad call");
        uint256 supply = hoodsSupply[hoodsSubject];
        require(supply > 0, "Hood is not release");
        require(msg.value > 0.01 ether, "appreciate amount invalid");
        subjectPump[hoodsSubject] = subjectPump[hoodsSubject] + msg.value;
    }

    //设置平台管理员地址
    function setFanshoodAdmin(address _fanshoodAdmin) public onlyOwner {
        fanshoodAdmin = _fanshoodAdmin;
    }

    //设置预售每个人最大可购买数量
    function setMaxPreAmount(uint256 _amount) public onlyOwner {
        maxPreAmount = _amount;
    }
}
