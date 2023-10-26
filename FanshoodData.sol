// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library FanshoodData {
    struct BookOption {
        bool isBook;
        //预售时间
        uint256 bookTime;
        //开放购买时间
        uint256 openTime;
        //merke根
        bytes32 whitelistRoot;
    }
}
