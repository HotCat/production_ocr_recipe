
#include "ZMotion/Motion.hpp"


ModbusZ::~ModbusZ(){
}


ModbusZ::ModbusZ(char* ipAddr){
  int ok;

  if(m_hCard != NULL) {
    ZAux_Close(m_hCard);
    m_hCard = NULL;
  }

  ok = ZAux_OpenEth(ipAddr, &m_hCard);
  if(ok != 0) {
    std::cout << "motion card connect failed! " << ok << std::endl;
  }
  CV_Assert(ok == 0);
}


void ModbusZ::closeZ(){
  if(m_hCard != NULL) {
    ZAux_Close(m_hCard);
    m_hCard = NULL;
  }
}


void ModbusZ::getFloat(uint16 start, uint16 inum, float* pdata){
  int ok;
  ok = ZMC_Modbus_GetIEEE(m_hCard, start, inum, pdata);
  if(ok != 0) {
    std::cout << "getFloat: " << ok << std::endl;
  }
  CV_Assert(ok == 0);
}


void ModbusZ::setFloat(uint16 start, uint16 inum, float* pdata){
  int ok;
  ok = ZMC_Modbus_SetIEEE(m_hCard, start, inum, pdata);
  if(ok != 0) {
    std::cout << "setFloat: " << ok << std::endl;
  }
  CV_Assert(ok == 0);
}


void ModbusZ::getBit(uint16 start, uint16 inum, uint8* pdata){
  int ok;
  ok = ZMC_Modbus_Get0x(m_hCard, start, inum, pdata);
  if(ok != 0) {
    std::cout << "getBit: " << ok << std::endl;
  }
  CV_Assert(ok == 0);
}


void ModbusZ::setBit(uint16 start, uint16 inum, uint8* pdata){
  int ok;
  ok = ZMC_Modbus_Set0x(m_hCard, start, inum, pdata);
  if(ok != 0) {
    std::cout << "setBit: " << ok << std::endl;
  }
  CV_Assert(ok == 0);
}

