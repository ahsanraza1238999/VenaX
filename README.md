# VenaX

VenaX is a lightweight Linux-based operating system designed to turn a spare PC into a private local AI server.

It runs Ollama locally and provides a web interface that other devices on the same network can access.

No cloud account is required — connect the VenaX machine to your network and use the provided local URL.

## Quick Start

### 1. Download VenaX

Download the latest pre-built VenaX ISO from the **Releases** section of this repository.

### 2. Download Rufus

Download Rufus from the official website:

https://rufus.ie/

### 3. Create a Bootable USB

1. Insert a USB drive into your computer.
2. Open Rufus.
3. Select your USB drive under **Device**.
4. Select the downloaded VenaX `.iso` under **Boot selection**.
5. Click **Start**.
6. Confirm the USB will be formatted and wait for the process to finish.

> **Warning:** Creating the bootable USB will erase the selected USB drive.

### 4. Boot VenaX

1. Insert the VenaX USB into the PC you want to use as the AI server.
2. Start or restart the PC.
3. Open the computer's **Boot Menu**.
4. Select the VenaX USB drive.
5. VenaX will boot and start its services.

### 5. Connect to Wi-Fi

After VenaX starts:

1. Follow the terminal instructions to select your Wi-Fi network.
2. Enter the Wi-Fi password.
3. Wait for VenaX to establish the network connection.

Ethernet can also be used.

### 6. Connect from Another Device

Once VenaX is connected to the network, it will display a local URL in the terminal.

On another device connected to the **same network**:

1. Open a web browser.
2. Enter the URL displayed by VenaX.
3. The VenaX web interface will open.
4. Use the interface to interact with your local AI server.

That's it. Your spare PC is now running as a local AI server.
