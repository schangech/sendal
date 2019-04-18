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
