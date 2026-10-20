// The app's demo fleet (RackbarCore/Resources/demo-fleet.json), with the
// labels `acme` and `zeta`. Addresses are from the RFC 5737 documentation
// ranges; nothing here exists.

export type Tone = 'live' | 'off' | 'busy' | 'bad';

export interface Server {
  name: string;
  status: string;
  tone: Tone;
  ipv4: string;
  type: string;
  location: string;
}

export interface Box {
  name: string;
  product: string;
  location: string;
  services: string[];
  fill: number;
}

export interface Project {
  label: string;
  servers: Server[];
  boxes: Box[];
}

export const fleet: Project[] = [
  {
    label: 'acme',
    servers: [
      { name: 'web-1', status: 'running', tone: 'live', ipv4: '203.0.113.10', type: 'cpx21', location: 'Falkenstein, DE' },
      { name: 'db-1', status: 'running', tone: 'live', ipv4: '203.0.113.11', type: 'ccx23', location: 'Falkenstein, DE' },
      { name: 'web-2', status: 'running', tone: 'live', ipv4: '203.0.113.12', type: 'cpx21', location: 'Nuremberg, DE' },
      { name: 'cache-1', status: 'off', tone: 'off', ipv4: '203.0.113.13', type: 'cx22', location: 'Falkenstein, DE' },
      { name: 'worker-1', status: 'starting', tone: 'busy', ipv4: '203.0.113.14', type: 'cax11', location: 'Helsinki, FI' },
      { name: 'bastion', status: 'running', tone: 'live', ipv4: '203.0.113.15', type: 'cx22', location: 'Falkenstein, DE' },
    ],
    boxes: [
      { name: 'backups', product: 'BX21', location: 'Falkenstein, DE', services: ['SSH', 'Samba'], fill: 0.29 },
    ],
  },
  {
    label: 'zeta',
    servers: [
      { name: 'app-1', status: 'running', tone: 'live', ipv4: '198.51.100.20', type: 'cpx11', location: 'Nuremberg, DE' },
      { name: 'db-1', status: 'running', tone: 'live', ipv4: '198.51.100.21', type: 'cx22', location: 'Nuremberg, DE' },
      { name: 'preview', status: 'off', tone: 'off', ipv4: '198.51.100.22', type: 'cx22', location: 'Helsinki, FI' },
    ],
    boxes: [],
  },
];

export const serverCount = fleet.reduce((n, p) => n + p.servers.length, 0);
