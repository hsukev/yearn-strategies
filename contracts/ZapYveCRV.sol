// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import {ICurveFi} from "../interfaces/curve.sol";
import {IUniswapV2Router02} from "../interfaces/uniswap.sol";
import {ISynthetix, IExchanger, ISynth} from "../interfaces/synthetix.sol";

interface IYVault is IERC20 {
    function deposit(uint256 amount, address recipient) external;

    function withdraw(uint256 shares, address recipient) external;

    function pricePerShare() external view returns (uint256);
}

contract ZapYveCRV is Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant uniswapRouter = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant sushiswapRouter = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    IYVault public yVault = IYVault(address(0x0e880118C29F095143dDA28e64d95333A9e75A47));
    ICurveFi public CurveStableSwap = ICurveFi(address(0xc5424B857f758E906013F3555Dad202e4bdB4567)); // Curve ETH/sETH StableSwap pool contract
    IUniswapV2Router02 public swapRouter;
    // IAddressResolver public SynthetixResolver = IAddressResolver(address(0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83)); // Synthetix AddressResolver contract
    ISynthetix public Synthetix = ISynthetix(address(0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F)); // Synthetix ProxyERC20
    IExchanger public SynthetixExchanger = IExchanger(address(0x0bfDc04B38251394542586969E2356d0D731f7DE));

    IERC20 public want = IERC20(address(0xA3D87FffcE63B53E0d54fAa1cc983B7eB0b74A9c)); // Curve.fi ETH/sETH (eCRV)
    IERC20 public WETH = IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ISynth public sETH = ISynth(address(0x5e74C9036fb86BD7eCdcb084a0673EFc32eA31cb)); // Synthetix ProxysETH
    ISynth public sUSD = ISynth(address(0x57Ab1ec28D129707052df4dF418D58a2D46d5f51)); // Synthetix ProxyERC20sUSD

    // uint256 public constant DEFAULT_SLIPPAGE = 50; // slippage allowance out of 10000: 5%
    bool private _noReentry = false;
    address[] public swapPathZapIn;
    address[] public swapPathZapOut;

    constructor() public Ownable() {
        swapRouter = IUniswapV2Router02(sushiswapRouter);

        swapPathZapIn = new address[](2);
        swapPathZapIn[0] = address(WETH);
        swapPathZapIn[1] = address(sUSD);

        swapPathZapOut = new address[](2);
        swapPathZapOut[0] = address(sUSD);
        swapPathZapOut[1] = address(WETH);

        // In approves
        IERC20(sETH).approve(address(CurveStableSwap), uint256(-1));
        IERC20(sUSD).approve(address(Synthetix), uint256(-1));
        want.safeApprove(address(yVault), uint256(-1));

        // Out approves
        want.safeApprove(address(CurveStableSwap), uint256(-1));
    }

    // accept ETH
    receive() external payable {
        if (_noReentry) {
            return;
        }
        _zapIn(0);
    }

    // Zap In - Step 1
    function estimateZapInWithSwap(uint256 ethAmount, uint256 percentSwapSeth) external view returns (uint256) {
        require(percentSwapSeth >= 0 && percentSwapSeth <= 100, "INVALID PERCENTAGE VALUE");

        uint256 expectedSethAmount = 0;
        if (percentSwapSeth > 0) {
            uint256 swappingEthAmount = ethAmount.mul(percentSwapSeth).div(100);
            expectedSethAmount = _calcSwapEthToSeth(swappingEthAmount);
        }
        uint256 remainingEthAmount = ethAmount.sub(expectedSethAmount);
        return CurveStableSwap.calc_token_amount([remainingEthAmount, expectedSethAmount], true);
    }

    function _calcSwapEthToSeth(uint256 ethAmount) internal view returns (uint256 expectedSethAmount) {
        uint256[] memory amounts = IUniswapV2Router02(swapRouter).getAmountsOut(ethAmount, swapPathZapIn);
        uint256 expectedSusdAmount = amounts[amounts.length - 1];
        (expectedSethAmount, , ) = SynthetixExchanger.getAmountsForExchange(expectedSusdAmount, "sUSD", "sETH");
    }

    // Zap In - Step 2 (optional)
    // Requires user to run: DelegateApprovals.approveExchangeOnBehalf(<zap_contract_address>)
    // Synthetix DelegateApprovals contract: 0x15fd6e554874B9e70F832Ed37f231Ac5E142362f
    function swapEthToSeth() external payable {
        uint256 swappingEthAmount = address(this).balance;
        IUniswapV2Router02(swapRouter).swapExactETHForTokens{value: swappingEthAmount}(swappingEthAmount, swapPathZapIn, address(this), now);

        uint256 susdAmount = sUSD.balanceOf(address(this));
        sUSD.transfer(msg.sender, susdAmount);
        Synthetix.exchangeOnBehalf(msg.sender, "sUSD", susdAmount, "sETH");
    }

    // Zap In - Step 3
    // Requires user to run: sETH.approve(<zap_contract_address>, <seth_amount>)
    // Synthetix ProxysETH contract: 0x5e74C9036fb86BD7eCdcb084a0673EFc32eA31cb
    function zapIn(uint256 sethAmount) external payable {
        if (_noReentry) {
            return;
        }
        // if (slippageAllowance == 0) {
        //     slippageAllowance = DEFAULT_SLIPPAGE;
        // }
        _zapIn(sethAmount);
    }

    function _zapIn(uint256 sethAmount) internal {
        uint256 ethBalance = address(this).balance;
        uint256 sethBalance = Math.min(sethAmount, sETH.balanceOf(msg.sender));
        require(ethBalance > 0 || sethBalance > 0, "INSUFFICIENT FUNDS");

        if (sethBalance > 0) {
            // uint256 waitLeft = SynthetixExchanger.maxSecsLeftInWaitingPeriod(msg.sender, "sETH");
            sETH.transferFromAndSettle(msg.sender, address(this), sethAmount);
        }

        CurveStableSwap.add_liquidity{value: ethBalance}([ethBalance, sethBalance], 0);

        uint256 outAmount = want.balanceOf(address(this));
        // require(outAmount.mul(slippageAllowance.add(10000)).div(10000) >= ethBalance.add(sethBalance), "TOO MUCH SLIPPAGE");

        yVault.deposit(outAmount, msg.sender);
    }

    // Zap Out - Step 1
    function estimateZapOut(uint256 yvTokenAmount) external view returns (uint256 ethWithdawalAmount, uint256 ethSwapedAmount) {
        uint256 yvTokenBalance = Math.min(yvTokenAmount, yVault.balanceOf(msg.sender));
        uint256 wantBalance = yvTokenAmount.mul(yVault.pricePerShare());

        ethWithdawalAmount = CurveStableSwap.calc_withdraw_one_coin(wantBalance, 0);

        uint256 sethWithdawalAmount = CurveStableSwap.calc_withdraw_one_coin(wantBalance, 1);
        ethSwapedAmount = _calcSwapSethToEth(sethWithdawalAmount);
    }

    function _calcSwapSethToEth(uint256 sethAmount) internal view returns (uint256 expectedEthAmount) {
        (uint256 expectedSusdAmount, , ) = SynthetixExchanger.getAmountsForExchange(sethAmount, "sETH", "sUSD");
        uint256[] memory amounts = IUniswapV2Router02(swapRouter).getAmountsOut(expectedSusdAmount, swapPathZapOut);
        expectedEthAmount = amounts[amounts.length - 1];
    }

    // Zap Out - Step 2
    // Requires user to run: DelegateApprovals.approveExchangeOnBehalf(<zap_contract_address>)
    // Synthetix DelegateApprovals contract: 0x15fd6e554874B9e70F832Ed37f231Ac5E142362f
    function zapOut(uint256 yvTokenAmount, int128 zeroIfEth) external {
        uint256 yvTokenBalance = Math.min(yvTokenAmount, yVault.balanceOf(msg.sender));
        require(yvTokenBalance > 0, "INSUFFICIENT FUNDS");

        yVault.withdraw(yvTokenBalance, address(this));
        uint256 wantBalance = want.balanceOf(address(this));

        _noReentry = true;
        CurveStableSwap.remove_liquidity_one_coin(wantBalance, zeroIfEth, 0);
        _noReentry = false;

        if (zeroIfEth == 0) {
            msg.sender.transfer(address(this).balance);
        } else {
            uint256 sethBalance = sETH.balanceOf(address(this));
            sETH.transfer(msg.sender, sethBalance);
            Synthetix.exchangeOnBehalf(msg.sender, "sETH", sethBalance, "sUSD");
        }

        uint256 leftover = yVault.balanceOf(address(this));
        if (leftover > 0) {
            yVault.transfer(msg.sender, leftover);
        }
    }

    // Zap In - Step 3 (Optional)
    // Requires user to run: sUSD.approve(<zap_contract_address>, <susd_amount>)
    // Synthetix ProxysETH contract: 0x5e74C9036fb86BD7eCdcb084a0673EFc32eA31cb
    function swapSusdToEth(uint256 susdAmount) external {
        uint256 susdBalance = Math.min(susdAmount, sUSD.balanceOf(msg.sender));
        require(susdBalance > 0, "INSUFFICIENT FUNDS");

        // uint256 waitLeft = SynthetixExchanger.maxSecsLeftInWaitingPeriod(msg.sender, "sUSD");
        sUSD.transferFromAndSettle(msg.sender, address(this), susdBalance);
        susdBalance = sUSD.balanceOf(address(this));
        IUniswapV2Router02(swapRouter).swapExactTokensForETH(susdBalance, 0, swapPathZapOut, address(this), now);
    }

    //There should never be any tokens in this contract
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        if (token == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            amount = Math.min(address(this).balance, amount);
            msg.sender.transfer(amount);
        } else {
            IERC20 want = IERC20(token);
            amount = Math.min(want.balanceOf(address(this)), amount);
            want.safeTransfer(msg.sender, amount);
        }
    }

    function updateVaultAddress(address _vault) external onlyOwner {
        yVault = IYVault(_vault);
        want.safeApprove(_vault, uint256(-1));
    }

    function setSwapRouter(
        bool isUniswap,
        address[] calldata _swapPathZapIn,
        address[] calldata _swapPathZapOut
    ) public onlyOwner {
        if (isUniswap) {
            swapRouter = IUniswapV2Router02(uniswapRouter);
        } else {
            swapRouter = IUniswapV2Router02(sushiswapRouter);
        }
        swapPathZapIn = _swapPathZapIn;
        swapPathZapIn = _swapPathZapOut;
        //  WETH.approve(swapRouter, uint256(-1));
    }
}
