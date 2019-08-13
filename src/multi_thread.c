#include "darknet.h"
#include "network.h"
#include "region_layer.h"
#include "cost_layer.h"
#include "utils.h"
#include "parser.h"
#include "box.h"
#include "demo.h"
#include "option_list.h"
#inculde "http_stream.h"

#include <pthread.h>
#include <assert.h>


extern void run_detector(int argc, char **argv);

struct arg_info{
    int argc;
    char **argv;
};

void * DOBY_IS_SLAVE(void * argument)
{
    struct arg_info *arg_info = argument;
    run_detector(arg_info->argc,arg_info->argv);
}


void multi_thread(int argc, char **argv)
{
    int thread_num = find_int_arg(argc, argv, "-thread_num",-1);
    int i;
    pthread_t tid;

    struct arg_info *arg_info = malloc(sizeof(struct arg_info));

    arg_info->argc = argc;
    arg_info->argv = argv;

    assert(thread_num != -1);
    for(i = 0; i< thread_num; i++){
        if(pthread_create(&tid, NULL,DOBY_IS_SLAVE, arg_info)) error("DOBBY IS FREEEEE\n");
    }
    
    pthread_join(tid, NULL);


}
