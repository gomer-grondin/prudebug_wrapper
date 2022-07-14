
#CC=arm-none-linux-gnueabi-gcc
CC=gcc

objs = prudbg.o cmdinput.o cmd.o printhelp.o da.o uio.o

prudebug : ${objs}
	${CC} ${objs} -o prudebug

install :
	sudo cp ./prudebug /usr/local/bin
