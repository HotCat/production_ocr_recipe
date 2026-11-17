
#include "ZMotion/zmotion.h"

class ModbusZ{

public:
	ModbusZ(char* ipAddr);
	~ModbusZ();

        void closeZ();

        void getFloat(uint16 start, uint16 inum, float* pdata);
        void setFloat(uint16 start, uint16 inum, float* pdata);

        void getBit(uint16 start, uint16 inum, uint8* pdata);
        void setBit(uint16 start, uint16 inum, uint8* pdata);

private:
        ZMC_HANDLE m_hCard = NULL;

};


