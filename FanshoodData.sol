// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library FanshoodData {
    struct BookOption {
        bool isBook;
        uint256 bookTime;
        uint256 openTime;
        bytes32 whitelistRoot;
    }
}
