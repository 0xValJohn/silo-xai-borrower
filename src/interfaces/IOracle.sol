
interface IOracle {
    function getPriceUsdcRecommended(
        address tokenAddress
    ) external view returns (uint256);
}