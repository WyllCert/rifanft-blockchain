// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Token de incentivos: oferta fija, sin mint posterior, con burn
contract RifaToken is ERC20, ERC20Burnable {
    uint256 public constant MAX_SUPPLY = 10_000_000 ether;

    constructor(address tesoreria, address equipo, address liquidez, address reserva)
        ERC20("RifaToken", "RIFA")
    {
        _mint(msg.sender, MAX_SUPPLY * 40 / 100); // 40% comunidad
        _mint(tesoreria, MAX_SUPPLY * 20 / 100);  // 20% tesorería
        _mint(equipo, MAX_SUPPLY * 15 / 100);     // 15% equipo
        _mint(liquidez, MAX_SUPPLY * 15 / 100);   // 15% liquidez
        _mint(reserva, MAX_SUPPLY * 10 / 100);    // 10% reserva
    }
}

/// Rifa con boletos NFT (proyecto de aprendizaje)
contract RifaNFT is ERC721, Ownable, Pausable, ReentrancyGuard {
    RifaToken public immutable rifaToken;
    address public immutable tesoreria;
    uint256 public immutable precioBoleto;
    uint256 public immutable fechaFin;
    uint256 public immutable minBoletos;
    uint256 public immutable maxBoletos;
    uint256 public immutable maxPorWallet;

    uint256 public constant COMISION_PCT = 5;
    uint256 public constant CASHBACK_POR_BOLETO = 100 ether;
    uint256 public constant QUEMA_POR_BOLETO = 10 ether;

    uint256 public totalBoletos;
    uint256 public pozo;
    bool public terminada;
    bool public cancelada;
    address public ganador;
    uint256 public boletoGanador;

    mapping(address => uint256) public boletosPorWallet;

    // Gobernanza simple
    string[] public causas;
    mapping(uint256 => uint256) public votos;
    mapping(address => bool) public yaVoto;

    event BoletoComprado(address indexed comprador, uint256 indexed idBoleto);
    event GanadorElegido(address indexed ganador, uint256 indexed idBoleto, uint256 premio);
    event RifaCancelada();
    event Reembolso(address indexed usuario, uint256 monto);
    event Voto(address indexed votante, uint256 indexed causa, uint256 peso);

    constructor(
        address _rifaToken,
        address _tesoreria,
        uint256 _precioBoleto,
        uint256 _duracionEnSegundos,
        uint256 _minBoletos,
        uint256 _maxBoletos,
        uint256 _maxPorWallet
    ) ERC721("Boleto Rifa", "TKT") Ownable(msg.sender) {
        require(_minBoletos > 0 && _minBoletos <= _maxBoletos, "Limites invalidos");
        require(_maxPorWallet > 0, "Limite por wallet invalido");

        rifaToken = RifaToken(_rifaToken);
        tesoreria = _tesoreria;
        precioBoleto = _precioBoleto;
        fechaFin = block.timestamp + _duracionEnSegundos;
        minBoletos = _minBoletos;
        maxBoletos = _maxBoletos;
        maxPorWallet = _maxPorWallet;
    }

    // NUEVA FUNCIÓN: Muestra los segundos que faltan en tiempo real
    function tiempoRestante() external view returns (uint256) {
        if (block.timestamp >= fechaFin) {
            return 0; // Ya terminó, listo para sortear
        }
        return fechaFin - block.timestamp; // Devuelve los segundos que quedan
    }

    function comprarBoletos(uint256 cantidad) external payable whenNotPaused nonReentrant {
        require(block.timestamp < fechaFin, "La rifa ya cerro");
        require(cantidad > 0, "Compra al menos 1 boleto");
        require(totalBoletos + cantidad <= maxBoletos, "Boletos agotados");
        require(boletosPorWallet[msg.sender] + cantidad <= maxPorWallet, "Limite por wallet");
        // require(msg.value == precioBoleto * cantidad, "Monto incorrecto");

        boletosPorWallet[msg.sender] += cantidad;
        pozo += msg.value;

        for (uint256 i = 0; i < cantidad; i++) {
            uint256 idBoleto = totalBoletos;
            totalBoletos++;
            _mint(msg.sender, idBoleto);
            emit BoletoComprado(msg.sender, idBoleto);
        }

        // Cashback en RIFA y quema (si hay fondos en el contrato)
        uint256 cashback = cantidad * CASHBACK_POR_BOLETO;
        uint256 quema = cantidad * QUEMA_POR_BOLETO;
        if (rifaToken.balanceOf(address(this)) >= cashback + quema) {
            rifaToken.transfer(msg.sender, cashback);
            rifaToken.burn(quema);
        }
    }

    function sortear() external nonReentrant {
        require(block.timestamp >= fechaFin, "Aun no termina el plazo");
        require(!terminada && !cancelada, "Rifa cerrada");
        require(totalBoletos >= minBoletos, "No se alcanzo el minimo");

        terminada = true;

        boletoGanador = uint256(
            keccak256(abi.encodePacked(block.prevrandao, block.timestamp, totalBoletos))
        ) % totalBoletos;

        ganador = ownerOf(boletoGanador);

        uint256 comision = (pozo * COMISION_PCT) / 100;
        uint256 premio = pozo - comision;
        pozo = 0;

        (bool okT, ) = payable(tesoreria).call{value: comision}("");
        require(okT, "Fallo comision");

        (bool okG, ) = payable(ganador).call{value: premio}("");
        require(okG, "Fallo premio");

        emit GanadorElegido(ganador, boletoGanador, premio);
    }

    function cancelarRifa() external {
        require(block.timestamp >= fechaFin, "Aun no termina el plazo");
        require(!terminada && !cancelada, "Rifa cerrada");
        require(totalBoletos < minBoletos, "Si alcanzo el minimo");

        cancelada = true;
        emit RifaCancelada();
    }

    function reembolsar() external nonReentrant {
        require(cancelada, "La rifa no fue cancelada");
        uint256 n = boletosPorWallet[msg.sender];
        require(n > 0, "Nada que reembolsar");

        boletosPorWallet[msg.sender] = 0;
        uint256 monto = n * precioBoleto;
        pozo -= monto;

        (bool ok, ) = payable(msg.sender).call{value: monto}("");
        require(ok, "Fallo reembolso");

        emit Reembolso(msg.sender, monto);
    }

    function agregarCausa(string calldata nombre) external onlyOwner {
        causas.push(nombre);
    }

    function votar(uint256 idCausa) external {
        require(idCausa < causas.length, "Causa inexistente");
        require(!yaVoto[msg.sender], "Ya votaste");

        uint256 peso = rifaToken.balanceOf(msg.sender);
        require(peso > 0, "Necesitas RIFA para votar");

        yaVoto[msg.sender] = true;
        votos[idCausa] += peso;

        emit Voto(msg.sender, idCausa, peso);
    }

    function pausar() external onlyOwner { _pause(); }
    function reanudar() external onlyOwner { _unpause(); }
}