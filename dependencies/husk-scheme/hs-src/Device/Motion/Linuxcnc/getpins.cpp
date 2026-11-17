#include <sys/ipc.h>
#include <sys/shm.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#include "hal.h"                /* HAL public API decls */

namespace linuxcnc {

  int t = 0;
  char *addr;
  char pinval[128];

  int t2 = 0;
  char *addr2;
  char posval[128];
  
  char* getpins ()
  {
    key_t key;
    int shmid;
  
    if(t==0) {
      key = ftok("linuxcnc",65);
      shmid = shmget(key,128,0666|IPC_CREAT);
      addr = (char*)shmat(shmid,(void*)0,0);
    }

    t=1;

    memcpy(pinval,addr,128);
    return pinval;
  }


}



