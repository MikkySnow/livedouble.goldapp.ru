pragma solidity ^0.5.11;

import "./Oraclize.sol";

contract Ownable {
    address payable public  owner;

    event OwnershipRenounced(address indexed previousOwner);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() public {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Permission denied!");
        _;
    }

    function transferOwnership(address payable newOwner ) public onlyOwner {
        require(newOwner != address(0), "Address is not valid!");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}


contract Enableble is Ownable{
    bool enable;

    modifier isWorking() {
        require(enable, "Not working!");
        _;
    }
    
    constructor() public {
        enable = true;
    }

    function setEnable(bool newStatus) public onlyOwner {
        enable = newStatus;
    }
}


contract LiveDouble is Enableble, usingOraclize {
    // выключатель вызова оракла
    bool public useOracle;
    uint256 public oraclizeGasLimit = 400000;
    uint256 public minRoundDuration = 60; // sec время, в течении которого еще можно успеть докинуть депозит
    address payable public commissionWallet;
    address payable public adminWallet;
    uint256 public commissionPercent = 100; //100 = 10%, 150=15%
    uint256 public percentMax = 1000;
    uint256 public ticketPrice = 0.001 ether;
    uint256 public maxTotalJp = 0;
    uint256 public sumTotalJp = 0;
    bool public drawInProcess = false;
    // хранилище для депозитов, которые пришли во время розыгрыша
    struct BufferDeposit {
        uint256 value;
        address payable user;
    }
    BufferDeposit[] public depositsBuffer;

    struct User {
        bool isExist;
        uint256 depositTotal;
        uint256 winTotal;
        uint256 gamesTotal;
    }
    mapping(address => User) public userAccounts;
    uint256 public usersCount;

    struct Round {
        uint256 ticketsTotal;
        uint256 ticketPrice;
        uint256 startDrawTime;
        uint256 startTime;
        uint256 endTime;
        uint256 winnerIndex;
        address payable[] users;
        mapping(address => uint256) tickets;
    }
    uint256 public currentRoundNumber;
    Round[] public rounds;

    event Deposit(
        address indexed player,
        uint256 indexed roundNumber,
        uint256 value,
        uint256 tickets,
        uint256 deposited,
        uint256 ticketsTotal
    );
    event Withdraw(address indexed player, uint256 value);
    event NewRound(uint256 roundNumber, uint256 startTime, uint256 minDuration);
    event StartTimer(uint256 roundNumber, uint256 time, uint256 duration);
    event StartDraw(uint256 roundNumber);
    event EndDraw(uint256 roundNumber, address payable winner, uint256 prize);
    event ForceStart();
    event Error(string message);
    event PaymentError(address User, uint256 value);
    
    modifier onlyAdminOrOwner() {
        require(owner==msg.sender || adminWallet==msg.sender, "Access denied!");
        _;
    }

    constructor(bool isUseOracle) public payable {
        useOracle = isUseOracle;
        commissionWallet = msg.sender;
        // нужно, чтобы начать раунд с нулевого индекса
        currentRoundNumber -= 1;
        createRound();
    }

    function() external payable {
        depositInternal(msg.sender, msg.value);
    }

    // депозит в текуий раунд
    function deposit() public payable isWorking {
        depositInternal(msg.sender, msg.value);
    }

    function depositInternal(address payable sender,uint value) private isWorking {
        if (
            drawInProcess ||
            (rounds[currentRoundNumber].startDrawTime + minRoundDuration < now && rounds[currentRoundNumber].startDrawTime != 0) ||
            rounds[currentRoundNumber].users.length >= 10
        ) {
            require(depositsBuffer.length<=10, "Buffer overflow!");
            depositsBuffer.push(BufferDeposit(value, sender));
        } else {
            Round storage currentRound = rounds[currentRoundNumber];
            // к-во билетов для покупки
            uint256 ticketToPurchase = value / currentRound.ticketPrice;
            User storage user = userAccounts[sender];
            if (!user.isExist) {
                // регистрируем
                user.isExist = true;
                usersCount+= 1;
            }
            // добавляем мелочь игроку в кошелек
            user.depositTotal += value;
            if (ticketToPurchase > 0) {
                // добавляем пользователя в список участников раунда, если его там нет
                if (currentRound.tickets[sender] == 0) {
                    currentRound.users.push(sender);
                    user.gamesTotal++;
                }
                // обновляем к-во тикетов игрока
                currentRound.tickets[sender] += ticketToPurchase;
                currentRound.ticketsTotal += ticketToPurchase;
                emit Deposit(
                    sender,
                    currentRoundNumber,
                    value,
                    ticketToPurchase,
                    ticketToPurchase * currentRound.ticketPrice,
                    currentRound.ticketsTotal
                );
                if (rounds[currentRoundNumber].users.length == 2 && rounds[currentRoundNumber].startDrawTime == 0){
                    rounds[currentRoundNumber].startDrawTime = now;
                    emit StartTimer(currentRoundNumber, now, minRoundDuration);
                }
                if (rounds[currentRoundNumber].users.length == 10){
                    emit ForceStart();
                } 
            }
        }
    }

    // попытка запустить закрытие раунда, может быть запущена админом или владельцом
    // при выполнении условий, закрывает раунд и запускает вызов оракла для генерации рандома
    function startDraw() public isWorking onlyAdminOrOwner {
        require(rounds[currentRoundNumber].startDrawTime!=0, "The round hasn’t started yet.");
        require((now > rounds[currentRoundNumber].startDrawTime + minRoundDuration) || rounds[currentRoundNumber].users.length >= 10, "Not time yet.");
        drawInProcess = true;
        rounds[currentRoundNumber].endTime = now;
        if (useOracle) {
            callOracleRandom();
        }
        emit StartDraw(currentRoundNumber);
    }
    // запуск розыгрыша с новыми параметрами для оракла
    function startDrawAdmin(uint256 gasLimit, uint256 gasPrice) public isWorking onlyAdminOrOwner {
        if (gasLimit!=0)
            setOraclizeGasLimit(gasLimit);
        if (gasPrice!=0)
            setCustomGasPrice(gasPrice);
        startDraw();
    }

    // метод для запуска запроса на рандом
    function callOracleRandom() internal {
        oraclize_setProof(proofType_Ledger);
        // количество рандомных байт для возвращения
        uint256 N = 16;
        // задержка отправки ответа от оракла
        uint256 delay = 0; 
        oraclize_newRandomDSQuery(delay, N, oraclizeGasLimit);
    }

    // определение победителя, вызывается в основном от оракла, но в крайнем случае может быть запущен админом
    function endDraw(uint256 seed) internal {
        // защита от двойного закрытия раунда
        require(drawInProcess == true, "Drawing hasn’t started yet.");
        Round storage currentRound = rounds[currentRoundNumber];
        uint256 randomTicket = seed % currentRound.ticketsTotal;
        uint256 ticketsCounter = 0;
        // проходим по всем билетам для определения победителя
        for (uint256 i = 0; i < currentRound.users.length; i++) {
            if (
                randomTicket < currentRound.tickets[currentRound.users[i]] + ticketsCounter
            ) {
                currentRound.winnerIndex = i;
                break;
            }
            ticketsCounter += currentRound.tickets[currentRound.users[i]];
        }
        address payable winnerAddress = currentRound.users[currentRound.winnerIndex];
        uint256 totalPrize = currentRound.ticketsTotal * currentRound.ticketPrice;
        uint256 commissionValue = (totalPrize * commissionPercent) / percentMax;
        uint256 winnerPrize = totalPrize - commissionValue;
        sumTotalJp += totalPrize;
        if (totalPrize > maxTotalJp) {
            maxTotalJp = totalPrize;
        }
        userAccounts[winnerAddress].winTotal += totalPrize;
        // пытаемся скинуть деньги, не критично, если что-то не выйдет
        if (!winnerAddress.send(winnerPrize)) {
            emit PaymentError(winnerAddress, winnerPrize);
        }
        if (!commissionWallet.send(commissionValue)) {
            emit PaymentError(commissionWallet, commissionValue);
        }
        emit EndDraw(currentRoundNumber, winnerAddress, totalPrize);
        drawInProcess = false;
        createRound();
    }
    
    function createRound() internal {
        currentRoundNumber += 1;
        Round memory newRound = Round(0, 0, 0, 0, 0, 0, new address payable[](0));
        newRound.startTime = now;
        newRound.ticketPrice = ticketPrice;
        rounds.push(newRound);
        emit NewRound(currentRoundNumber, now, minRoundDuration);
        for (uint i = 0; i < depositsBuffer.length; i++){
            depositInternal(depositsBuffer[i].user, depositsBuffer[i].value);
        }
        depositsBuffer.length = 0;
    }

    // точка входа для оракла
    function __callback(
        bytes32 _queryId,
        string memory _result,
        bytes memory _proof
    ) public {
        require(msg.sender == oraclize_cbAddress(), "oraclize only");
        endDraw(uint256(keccak256(abi.encode(_result))));
    }

    // ------------------- методы суперпользователей ----------------------
    // ручное закрытие игры для особого случая
    function ownerEndDraw(uint256 seed) public onlyAdminOrOwner {
        if (!drawInProcess){
            require(rounds[currentRoundNumber].startDrawTime!=0, "The round hasn’t started yet.");
            require(now > rounds[currentRoundNumber].startDrawTime + minRoundDuration, "Not time yet.");
            drawInProcess = true;
            rounds[currentRoundNumber].endTime = now;
            if (useOracle)
                callOracleRandom();
            emit StartDraw(currentRoundNumber);
        }
        endDraw(uint256(keccak256(abi.encode(seed))));
    }

    function ownerWithdraw(uint256 value) public onlyOwner {
        require(address(this).balance >= value, "not enough money to withdraw");
        owner.transfer(value);
    }

    // пополнение баланса контракта в случае необходимости
    function donate() external payable {}

    function setMinRoundDuration(uint256 newValue) public onlyOwner {
        minRoundDuration = newValue;
    }

    function setCommissionWallet(address payable newValue) public onlyOwner {
        commissionWallet = newValue;
    }
    
    function setAdmin(address payable newValue) public onlyOwner {
        adminWallet = newValue;
    }

    function setCommissionPercent(uint256 newValue) public onlyOwner {
        require(newValue <= percentMax, "Commission can be more than 100%!");
        commissionPercent = newValue;
    }

    function setOraclizeGasLimit(uint256 newValue) public onlyAdminOrOwner {
        oraclizeGasLimit = newValue;
    }
    
    function setCustomGasPrice(uint _gasPrice) public onlyAdminOrOwner {
        oraclize_setCustomGasPrice(_gasPrice);
    }

    // подействует только после окончания текущей игры (иначе могут возникнуть сложности с выплатой)
    function setTicketPrice(uint256 newValue) public onlyOwner {
        require(newValue > 0, "Price must be more than zero!");
        ticketPrice = newValue;
    }
    
    function isAdmin(address _admin) public view returns(bool) {
        return _admin==adminWallet;
    }
    
    function isOwner(address _owner) public view returns(bool) {
        return _owner==owner;
    }

    // ----------------- методы получения статистики ----------------------
    function getPlayerTicketsCount(address player, uint256 roundNumber)
        public
        view
        returns (uint256)
    {
        return rounds[roundNumber].tickets[player];
    }

    function getRoundPlayersCount(uint256 roundNumber)
        public
        view
        returns (uint256)
    {
        return rounds[roundNumber].users.length;
    }

    function getRoundPlayer(uint256 roundNumber, uint256 index)
        public
        view
        returns (address, uint256)
    {
        return (
            rounds[roundNumber].users[index],
            rounds[roundNumber].tickets[rounds[roundNumber].users[index]]
        );
    }

    function getTotalPlayerCount() public view returns (uint256) {
        return usersCount;
    }

    function getCurrentJp() public view returns (uint256) {
        //currentRound.ticketsTotal * currentRound.ticketPrice
        return rounds[currentRoundNumber].ticketsTotal * rounds[currentRoundNumber].ticketPrice;
    }

    function getMaxJpForPeriod(uint256 fromTimestamp)
        public
        view
        returns (uint256 maxJp)
    {
        uint256 currNumber = currentRoundNumber;
        while (true) {
            if (
                currNumber == currentRoundNumber ||
                rounds[currNumber].endTime >= fromTimestamp
            ) {
                uint256 jp = rounds[currNumber].ticketPrice *
                    rounds[currNumber].ticketsTotal;
                if (jp > maxJp) {
                    maxJp = jp;
                }
            } else {
                break;
            }
            if (currNumber == 0) break;
            else currNumber--;
        }
    }
}