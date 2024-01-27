//SPDX-Indentifier-License: MIT

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 * @title DSCEngine
 * @author QuiV
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 * Our DSC system should always be overcollateralized. At no point, shoud the value of all collateral <= the backed value of all the DSC.
 * 
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    ////Error////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLenght();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /// State Variables//// 

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% 


    mapping(address token => address priceFeed) private s_priceFeeds;  // maps token to priceFeed
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address [] private s_collateralTokens;



    DecentralizedStableCoin private  immutable i_dsc;

    /// Event////


    // if redeemFrom != redeemTo -> liquidated
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);


    ///// Modifier//// 
    modifier moreThanZero(uint256 amount){
        if(amount == 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token){
        if (s_priceFeeds[token]== address(0)){
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }


    //// Function //// 
    constructor(
        address[] memory tokenAddresses, 
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // compare number of token in the two mappings
        if(tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLenght();
        }
        // loop through token list to match that token price feed
        for (uint256 i = 0; i<tokenAddresses.length; i ++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);

    }


    //// External Function //// 

     /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
        ) external {
            depositCollateral(tokenCollateralAddress,amountCollateral);
            mintDsc(amountDscToMint);

        }

    function depositCollateral(
        address tokenCollateralAddress,           //must be our pre-determined tokens: wBTC,wETH
        uint256 amountCollateral                  // Needs more than zero
    ) 
    public 
        moreThanZero(amountCollateral) 
        isAllowedToken(tokenCollateralAddress) 
        nonReentrant // a modifier belongs to RenentrancyGuard 
     {
       
    }

         /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will redeem and burn your DSC in one transaction
     */

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) 
        external moreThanZero(amountDscToBurn)
    {
        _burnDsc(amountDscToBurn,msg.sender,msg.sender);
        _redeemCollateral(tokenCollateralAddress,amountCollateral,msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }


    /*
    * @notice follows CEI ( Check - Effect - Interaction)
    * @param amountDscToMint - the amount of decentralized stablecoin to mint
    * @notice they must have more collateral value than the minimum threshold.

    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted){
            revert DSCEngine_MintFailed();
        }
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */

    function liqudate(address collateral, address user, uint256 debtToCover) 
        external 
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtToCovered = getTokenAmountFromUsd(collateral,debtToCover);
        // 10% bonus for liquidator
        uint256 bonusCollateral = (tokenAmountFromDebtToCovered * LIQUIDATION_BONUS)/ LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtToCovered + bonusCollateral;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(collateral,totalCollateralToRedeem,user,msg.sender);
        _burnDsc(debtToCover,user,msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor < startingUserHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender); //if the whole liquidating process ruins their health factor, revert it.

    }


    function getHealthFactor() external view {}


    /// Private Function////

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool sucess = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!sucess){
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @dev: low-level internal function, do not call unless function calling it is checking for 
     * health factor being broken.
    */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom)
        private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool sucess = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!sucess){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }


    //// Internal & Private View Function////

    function _getAccountInformation(address user) 
        private
        view
        returns(uint256 totalDscMinted,uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
    * Returns how closed to liquidation a user is
    * If a user goes below 1, then they can get liquidated.
    */
    function _healthFactor(address user) private view returns (uint256){
        // total DSCMinted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collatearalValueInUsd) = _getAccountInformation(user);

        uint256 collatearalAdjustedForThreshold = (collatearalValueInUsd * LIQUIDATION_THRESHOLD)/ 
        LIQUIDATION_PRECISION;

        return (collatearalAdjustedForThreshold * PRECISION)/totalDscMinted;

    }
    // Check health factor ( enough collateral?) & revert if they dont
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
  


    //// Public & External View Functions ////
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }
    
    
    
    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd){
        // loop through each collateral token: s_collateralTokens[], get the amount they have deposited
        // & map it tho the priceFeed, get the USD value

        for (uint256 index = 0; index <s_collateralTokens.length; index ++){
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd +=getUsdValue(token,amount);
        }
        return totalCollateralValueInUsd;

    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData(); //returned value will be price in integer * 1e8

        return ((uint256 (price) * ADDITIONAL_FEED_PRECISION) * amount)/ PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }
}