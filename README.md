Kali-ARM Build-Scripts
======================

We use these to build our official Kali Linux ARM images, as can be found at https://www.kali.org/downloads/

- These scripts have been tested on a Kali Linux 32-bit and 64-bit installations only, after making sure that all the dependencies have been installed.
- Make sure you run the `build-deps.sh` script first, which installs all required dependencies.

**_IF YOU ARE BUILDING IN A VM, YOU WILL NEED TO DEDICATE AT LEAST 8GB OF RAM, OR USE A SWAP FILE_**

A sample workflow would look similar to (armhf):

```
mkdir -p ~/arm-stuff/
cd ~/arm-stuff/
git clone https://gitlab.com/kalilinux/build-scripts/kali-arm ~/arm-stuff/kali-arm/
cd ~/arm-stuff/kali-arm/
./build-deps.sh
./pinebook-pro.sh 2021.2
```

If you are on 32-bit, after the script finishes running, you will have an image file located in `~/arm-stuff/kali-arm/` called `kali-linux-2021.2-pinebook-pro.img`.

32-bit does not have enough memory to compress the image.
**_You will need to use your own preferred compression if you want to distribute it._**

On 64-bit systems, after the script finishes running, you will have an image files located in `~/arm-stuff/kali-arm/` called `kali-linux-2021.2-pinebook-pro.img.xz`.

Last Updated: 2021-Apr-26 08:38:23 UTC
