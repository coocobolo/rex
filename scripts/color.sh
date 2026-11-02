#!/usr/bin/env bash

# 256-color palette
for i in $(seq 0 255); do  
  printf '\033[38;5;%dm %3d \033[0m' $i $i  
  [ $((($i+1) % 16)) -eq 0 ] && echo  
done

# ansi 16-colors basic
printf '\033[31mRed\033[0m \033[32mGreen\033[0m \033[33mYellow\033[0m\n'  
printf '\033[1;31mBold Red\033[0m \033[1;32mBold Green\033[0m\n'

# True color (RGB)
printf '\033[31mRed\033[0m \033[32mGreen\033[0m \033[33mYellow\033[0m\n'  
printf '\033[1;31mBold Red\033[0m \033[1;32mBold Green\033[0m\n'

# background colors
printf '\033[41m Red BG \033[0m \033[42m Green BG \033[0m\n'