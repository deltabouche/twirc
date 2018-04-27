# TWIRC

Twitter/IRC bridge

**Disclaimer** – This is very messy old code provided as-is, it needs a lot of organization and improvement. No tests. Documentation is sparse. Most things aren't configurable and you'll need to dig into the source to figure things out. It's not the most secure thing on earth (for example there is an unprotected `eval` command) and needs a major security overhaul if it is going to be exposed to the public. It was never intended to be used beyond a shared private server with a few friends.

## Prerequisites

* Ruby 2.4.1
* Bundler

## Installation

    git clone https://github.com/deltabouche/twirc.git

    bundle

## Configuration

    cp .env.example .env

Edit your .env file with the following variables:

* **TWITTER_CLIENT_ID**: Your Twitter App Client ID
* **TWITTER_CLIENT_SECRET**: Your Twitter App Client secret
* **SALT1**–**SALT4**: Random strings for salting passwords
* **BF_KEY**: Blowfish key (16 chars) for encrypting user tokens

## Run TWIRC

    ruby nubee.rb

## Using TWIRC

Connect to your server using an IRC client on port 9198. Although it is not required, it's recommended you set your nickname to your Twitter handle.

### Registering your user

This process works a lot like NICKSERV services on standard IRC networks. 

    /msg NICKSERV REGISTER <password>

You will be prompted to visit a URL to retrieve an OAuth code for your logged in Twitter account. Your nickname does not need to match your Twitter handle, however this will be the name that you need to IDENTIFY as on future connections to the server to access your Twitter account. 

Follow the instruction prompts from NICKSERV to complete the process.

When you reconnect to the server, you can use the following command to authenticate yourself and be connected to the Twitter services.

    /msg NICKSERV IDENTIFY <password>

### Using the service

Once you've connected to the server you will be automatically joined to a **&amp;control** channel. Once you've logged in using REGISTER or IDENTIFY, then you will be joined to the **#timeline** channel.

This is where you will receive your feed, and where you will use the majority of commands.

To list commands and get command help simply type in `?`.

Anything that takes an `id or url` can be a Tweet Short ID (the 3 character identifiers in square brackets such as `[4AD]`) or a full Twitter Status URL.
