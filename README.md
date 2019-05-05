# sendal
Beijing

### 解决ubuntu环境下sublime中文输入问题
https://github.com/lyfeyaj/sublime-text-imfix

### ubuntu ss
```bash
sudo add-apt-repository ppa:hzwhuang/ss-qt5
sudo apt-get update
sudo apt-get install shadowsocks-qt5
```

### global ss
```bash
sudo apt-get install proxychains
```


```bash
socks5    127.0.0.1    1080

strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
localnet 127.0.0.0/255.0.0.0
quiet_mode

[ProxyList]
socks5  127.0.0.1 1080

```

# install zsh
1. sudo apt-get install fonts-powerline
2. https://github.com/robbyrussell/oh-my-zsh
3. cp .zshrc ~

# install git flow
sudo apt install git-flow

# vim bunder plugin manager
https://github.com/VundleVim/Vundle.vim

sudo apt install build-essential cmake python3-dev

# color schema
1. mkdir ~/.vim/colors
2. cp ~/.vim/bundle/vim-colors-solarized/colors/solarized.vim ~/.vim/colors/

# YouCompleteMe
1. sudo apt install build-essential cmake python3-dev
2. ./install.py --clang-completer
3. ref: https://github.com/Valloric/YouCompleteMe#linux-64-bit

# python3
sudo apt-get install zlib1g-dev
sudo apt-get install libffi-dev

# vim
https://github.com/spf13/spf13-vim
curl https://j.mp/spf13-vim3 -L > spf13-vim.sh && sh spf13-vim.sh

# ubuntu top icons
sudo apt-get install chrome-gnome-shell

