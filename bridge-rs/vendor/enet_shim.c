/* 最小 ENet C 胶水：只暴露 Rust 需要的几个调用，POD 事件结构避免绑定布局问题。 */
#include <enet/enet.h>
#include <string.h>
#include <sys/socket.h>

typedef struct {
    int type;             /* 0 none, 1 connect, 2 disconnect, 3 receive */
    void *peer;
    int channel;
    int len;
} tb_event;

static ENetHost *g_host = NULL;

int tb_init(void) { return enet_initialize(); }

void *tb_host_create(int peers, int channels) {
    ENetAddress addr;
    memset(&addr, 0, sizeof(addr));
    addr.addressLength = sizeof(struct sockaddr_in);
    enet_address_set_host(&addr, "0.0.0.0");
    enet_address_set_port(&addr, 0);
    g_host = enet_host_create(AF_INET, &addr, (size_t)peers, (size_t)channels, 0, 0);
    return g_host;
}

int tb_connect(void *host, const char *ip, unsigned short port, int channels, unsigned int connect_data, void **out_peer) {
    ENetAddress addr;
    memset(&addr, 0, sizeof(addr));
    addr.addressLength = sizeof(struct sockaddr_in);
    if (enet_address_set_host(&addr, ip) != 0) return -1;
    enet_address_set_port(&addr, port);
    ENetPeer *peer = enet_host_connect((ENetHost *)host, &addr, (size_t)channels, connect_data);
    if (!peer) return -2;
    *out_peer = peer;
    return 0;
}

/* 返回 1 表示有事件；事件数据已拷贝到 buf。 */
int tb_service(void *host, int timeout_ms, tb_event *ev, unsigned char *buf, int buflen) {
    ENetEvent e;
    int r = enet_host_service((ENetHost *)host, &e, timeout_ms);
    if (r <= 0) return 0;
    ev->peer = e.peer;
    ev->channel = e.channelID;
    ev->len = 0;
    switch (e.type) {
    case ENET_EVENT_TYPE_CONNECT: ev->type = 1; break;
    case ENET_EVENT_TYPE_DISCONNECT: ev->type = 2; break;
    case ENET_EVENT_TYPE_RECEIVE:
        ev->type = 3;
        ev->len = (int)e.packet->dataLength;
        if (ev->len > buflen) ev->len = buflen;
        memcpy(buf, e.packet->data, (size_t)ev->len);
        enet_packet_destroy(e.packet);
        break;
    default: ev->type = 0; break;
    }
    return 1;
}

int tb_send(void *peer, int channel, const unsigned char *data, int len, int reliable) {
    ENetPacket *p = enet_packet_create(data, (size_t)len, reliable ? ENET_PACKET_FLAG_RELIABLE : 0);
    if (!p) return -1;
    if (enet_peer_send((ENetPeer *)peer, (enet_uint8)channel, p) != 0) {
        enet_packet_destroy(p);
        return -2;
    }
    return 0;
}

void tb_flush(void *host) { enet_host_flush((ENetHost *)host); }

int tb_peer_state(void *peer) { return (int)((ENetPeer *)peer)->state; }

void tb_destroy(void *host) {
    enet_host_destroy((ENetHost *)host);
    enet_deinitialize();
}
