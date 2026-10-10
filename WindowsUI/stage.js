// The stage to the right of the side panes: the 3D board, turned to show
// the part each pane is about, with a caption. Settings' Popup tab shows the
// popup preview in its place. Where WebGL is missing, a flat drawing of the
// board stands in.

import { drawBoard } from './board2d.js';
import { h } from './ui.js';
import { PopupPreview } from './popup.js';

const CAPTIONS = {
  editor: 'Apple M0110',
  popup: 'Apple M0110',
  gestures: 'Soli Radar Chip',
  battery: '10,000 mAh LiPo cell',
  radio: 'Bluetooth Chip',
};

export class Stage {
  constructor(column, app) {
    this.app = app;
    this.column = column;
    this.view = h('div.stage-view');
    this.caption = h('div.stage-caption', {}, h('div.small', { style: { fontWeight: 600 } }), h('div.small.dim.mono'));
    this.frame = h('div.panel.stage', {}, this.view, this.caption);
    this.popup = new PopupPreview(app);
    column.append(this.frame, this.popup.node);
    this.focusName = null;
    this.board = null;
  }

  setBoard(board) {
    this.board = board;
    this.drawBoard();
  }

  drawBoard() {
    const board3d = this.app.board3d;
    if (board3d) {
      if (this.focusName == null || this.focusName === 'popup') return;
      board3d.onPick = null;
      this.view.replaceChildren(board3d.canvas);
      board3d.paint(null, null, true);
      board3d.setFocus(this.focusName);
      board3d.wake();
      return;
    }
    if (!this.board) return;
    this.view.classList.add('flat');
    const width = Math.max(200, this.view.clientWidth - 40);
    drawBoard(this.view, { board: this.board, slots: null, selected: null, plain: true, width });
  }

  /** Which part of the board to show: editor, popup, gestures, battery,
   *  radio, or null for no stage. */
  focus(name) {
    this.focusName = name;
    this.column.hidden = name == null;
    this.frame.hidden = name === 'popup';
    this.popup.setActive(name === 'popup');
    this.frame.dataset.focus = name ?? '';
    requestAnimationFrame(() => this.drawBoard());
    this.update(this.app);
  }

  update(app) {
    const [title, detail] = this.caption.children;
    title.textContent = CAPTIONS[this.focusName] ?? '';
    detail.textContent = this.focusName === 'battery' ? batteryDetail(app) : '';
    detail.hidden = !detail.textContent;
    if (this.focusName === 'popup') this.popup.update(app);
    const settings = app.state?.settings;
    if (app.board3d && settings) {
      const device = app.state.device;
      app.board3d.setBattery(device?.linked ? device.battery : null, settings.lowThreshold, settings.rearmThreshold);
    }
  }
}

/** BoardStage's battery line. */
function batteryDetail(app) {
  const device = app.state?.device;
  const settings = app.state?.settings ?? { lowThreshold: 20, rearmThreshold: 30 };
  if (!device?.linked) return 'Not connected';
  if (device.battery == null) return 'Connected, battery not read yet';
  const level = device.battery;
  const word = level <= settings.lowThreshold ? 'Low' : level <= settings.rearmThreshold ? 'Getting low' : 'Charged';
  return `${level}% · ${word}`;
}
